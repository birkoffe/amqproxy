require "./amqproxy/version"
require "./amqproxy/server"
require "option_parser"
require "uri"
require "ini"
require "logger"
require "crometheus"

class AMQProxy::CLI
  @listen_address = ENV["LISTEN_ADDRESS"]? || "localhost"
  @listen_port = ENV["LISTEN_PORT"]? || 5673
  @log_level : Logger::Severity = Logger::INFO
  @idle_connection_timeout : Int32 = ENV.fetch("IDLE_CONNECTION_TIMEOUT", "5").to_i
  @upstream = ENV["AMQP_URL"]?

  def parse_config(path)
    INI.parse(File.read(path)).each do |name, section|
      case name
      when "main", ""
        section.each do |key, value|
          case key
          when "upstream"                then @upstream = value
          when "log_level"               then @log_level = Logger::Severity.parse(value)
          when "idle_connection_timeout" then @idle_connection_timeout = value.to_i
          else                                raise "Unsupported config #{name}/#{key}"
          end
        end
      when "listen"
        section.each do |key, value|
          case key
          when "port"            then @listen_port = value
          when "bind", "address" then @listen_address = value
          when "log_level"       then @log_level = Logger::Severity.parse(value)
          else                        raise "Unsupported config #{name}/#{key}"
          end
        end
      else raise "Unsupported config section #{name}"
      end
    end
  rescue ex
    abort ex.message
  end

  def run
    p = OptionParser.parse do |parser|
      parser.banner = "Usage: amqproxy [options] [amqp upstream url]"
      parser.on("-l ADDRESS", "--listen=ADDRESS", "Address to listen on (default is localhost)") do |v|
        @listen_address = v
      end
      parser.on("-p PORT", "--port=PORT", "Port to listen on (default: 5673)") { |v| @listen_port = v.to_i }
      parser.on("-t IDLE_CONNECTION_TIMEOUT", "--idle-connection-timeout=SECONDS", "Maxiumum time in seconds an unused pooled connection stays open (default 5s)") do |v|
        @idle_connection_timeout = v.to_i
      end
      parser.on("-d", "--debug", "Verbose logging") { @log_level = Logger::DEBUG }
      parser.on("-c FILE", "--config=FILE", "Load config file") { |v| parse_config(v) }
      parser.on("-h", "--help", "Show this help") { puts parser.to_s; exit 0 }
      parser.on("-v", "--version", "Display version") { puts AMQProxy::VERSION.to_s; exit 0 }
      parser.invalid_option { |arg| abort "Invalid argument: #{arg}" }
    end

    @upstream ||= ARGV.shift?
    upstream_url = @upstream || abort p.to_s

    u = URI.parse upstream_url
    abort "Invalid upstream URL" unless u.host
    default_port =
      case u.scheme
      when "amqp"  then 5672
      when "amqps" then 5671
      else              abort "Not a valid upstream AMQP URL, should be on the format of amqps://hostname"
      end
    port = u.port || default_port
    tls = u.scheme == "amqps"

    server = AMQProxy::Server.new(u.host || "", port, tls, @log_level, @idle_connection_timeout)

    info = Crometheus::Gauge[:version].new(
      :build_info,
      "AMQProxy build info")
    info[version: AMQProxy::VERSION.to_s.rstrip].set 1.0

    Crometheus.default_registry.port = 5001
    Crometheus.default_registry.namespace = "amqproxy"
    Crometheus.default_registry.start_server

    first_shutdown = true
    shutdown = ->(_s : Signal) do
      if first_shutdown
        first_shutdown = false
        server.stop_accepting_clients
      else
        server.disconnect_clients
      end
    end
    Signal::INT.trap &shutdown
    Signal::TERM.trap &shutdown

    server.listen(@listen_address, @listen_port.to_i)

    # wait until all client connections are closed
    until server.client_connections.zero?
      sleep 0.2
    end
  end
end

AMQProxy::CLI.new.run
