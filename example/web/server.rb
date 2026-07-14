# frozen_string_literal: true

require "async"
require "async/http"
require "protocol/http/response"

require_relative "../../lib/klenod"
require_relative "update_logger"

config = Klenod::Build::ConfigLoader.load(File.expand_path("klenod.config.rb", __dir__))
source_dir = config.source_path
entrypoint = config.entrypoints.fetch(0)
port = Integer(ENV.fetch("PORT", "9292"))
assets_dir = ENV["ASSETS_DIR"] && File.expand_path(ENV.fetch("ASSETS_DIR"))
endpoint = Async::HTTP::Endpoint.parse("http://localhost:#{port}")

context = config.context
entry = context.entry(entrypoint)
watcher = Klenod::Dev::Watcher.new(source_dir: source_dir, context: context)
context.write_assets(assets_dir) if assets_dir
asset_app = Klenod::HTTP::AssetApp.new(context, assets_dir: assets_dir)
update_logger = Example::UpdateLogger.new(source_dir: source_dir)

context.on_update do |event|
  start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  update = context.apply_update(event, entry: entry, assets_dir: assets_dir)

  update_logger.log(event: event, update: update, duration: duration_ms(start_time)) do |module_id, error|
    format_update_error(module_id, error, context)
  end
end

def format_exception(error, context)
  mods =
    context.graph.mods.each_with_object({}) do |(module_id, mod), index|
      index[module_id.to_s] = mod
      index[module_id.path] = mod
    end

  Klenod::BacktraceRewriter.new(mods).format_exception(error)
end

def format_update_error(module_id, error, context)
  return format_parse_update_error(error) if error.is_a?(Klenod::Build::Plugins::HamlPlugin::ParseError)

  [
    "#{module_id}: #{error.class}",
    error.message,
    source_context_for_update_error(module_id, error, context)
  ].compact.join("\n\n")
end

def format_parse_update_error(error)
  reset = "\e[0;48;5;52m"
  lines = error.message.lines
  title = lines.shift&.chomp || "#{error.class}: #{error.message}"
  body = lines.join

  [
    "\e[1;31;47m ERROR \e[3;31;47m #{title} #{reset}",
    body.empty? ? nil : color_parse_error_body(body),
    "\e[0m"
  ].compact.join("\n")
end

def color_parse_error_body(body)
  body
    .sub(/\A\n+/, "")
    .sub(/\A(.+?)(\n\n|\z)/m) { "\e[1;31m#{$1}\e[0;48;5;52m#{$2}" }
    .sub(/^Source:/, "\e[1;34mSource:\e[0;48;5;52m")
end

def source_context_for_update_error(module_id, error, context)
  return nil if error.is_a?(Klenod::Build::Plugins::HamlPlugin::ParseError)
  return nil unless error.respond_to?(:line)

  source_path = context.graph.absolute_path(module_id)
  return nil unless source_path.file?

  line = error.line
  return nil unless line.is_a?(Integer)

  # Haml reports zero-based line indexes.
  line += 1
  source_excerpt(File.read(source_path), line)
end

def source_excerpt(source, line)
  lines = source.lines
  return nil if lines.empty?

  index = line - 1
  first = [index - 2, 0].max
  last = [index + 2, lines.length - 1].min
  width = (last + 1).to_s.length
  excerpt =
    (first..last).map do |line_index|
      marker = (line_index == index) ? ">" : " "
      number = (line_index + 1).to_s.rjust(width)
      formatted = "#{marker} #{number} | #{lines.fetch(line_index).chomp}"
      if marker == ">"
        "\e[1;31m#{formatted}\e[0m"
      else
        formatted
      end
    end

  "Source:\n#{excerpt.join("\n")}"
end

def indent_lines(value, indent)
  value.lines.map { |line| "#{indent}#{line}" }.join
end

def strip_ansi(value)
  value.gsub(/\e\[[0-9;]*m/, "")
end

def duration_ms(start_time)
  format("%.4fms", (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000)
end

def color_status(status)
  color =
    case status
    when 200..299 then 32
    when 300..399 then 36
    when 400..499 then 33
    else 31
    end

  "\e[#{color}m#{status}\e[0m"
end

def color(name, value)
  return value.to_s if ENV["NO_COLOR"]

  colors = {
    reset: "\e[0m",
    dim: "\e[2m",
    title: "\e[1;36m",
    label: "\e[1;37m",
    value: "\e[32m"
  }

  "#{colors.fetch(name)}#{value}#{colors.fetch(:reset)}"
end

def asset_request?(path)
  path.start_with?("/assets/")
end

def log_request(request, status, start_time)
  method = request&.method.to_s.empty? ? "GET" : request.method.to_s.upcase
  path = request&.path.to_s.empty? ? "/" : request.path
  line = "#{method} #{path} -> #{color_status(status)} (#{duration_ms(start_time)})"
  line = "\e[2m#{line}\e[0m" if asset_request?(path)

  puts line
end

def protocol_response(status, headers, body)
  Protocol::HTTP::Response[status, headers, body]
end

def suppress_io_buffer_experimental_warning
  return unless defined?(IO::Buffer)

  previous = Warning[:experimental]
  Warning[:experimental] = false
  IO::Buffer.new(0)
ensure
  Warning[:experimental] = previous unless previous.nil?
end

def log_startup(port:, source_dir:, assets_dir:)
  puts color(:title, "Klenod example server")
  puts "  #{color(:label, "url")}      #{color(:value, "http://localhost:#{port}")}"
  puts "  #{color(:label, "watching")} #{source_dir}"
  puts "  #{color(:label, "assets")}   #{assets_dir || color(:dim, "in memory")}"
end

suppress_io_buffer_experimental_warning
log_startup(port:, source_dir:, assets_dir:)

begin
  watcher.start

  Async do
    server =
      Async::HTTP::Server.for(endpoint) do |request|
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        if (asset_response = asset_app.response_for(request.path))
          status, headers, body = asset_response.status, asset_response.headers, [asset_response.body]
        else
          status, headers, body = entry.call(request, context)
        end
        log_request(request, status, start_time)
        protocol_response(status, headers, body)
      rescue => e
        formatted = format_exception(e, context)
        warn formatted
        log_request(request, 500, start_time) if start_time
        protocol_response(500, {"content-type" => "text/plain"}, [strip_ansi(formatted), "\n"])
      end

    server.run.wait
  end
ensure
  watcher&.stop
end
