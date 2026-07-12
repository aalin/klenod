# frozen_string_literal: true

require "async"
require "async/http"
require "protocol/http/response"

require_relative "../../lib/klenod"

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

context.on_update do |event|
  update = context.apply_update(event, entry: entry, assets_dir: assets_dir)

  if update.failed?
    warn "Update ##{event.graph_version} failed"
    update.error_messages.each { |message| warn "  #{message}" }
  else
    puts "Update ##{event.graph_version}: dependency tree updated"
    unless event.asset_changes.empty?
      puts "  assets added: #{event.asset_changes.added.join(", ")}" unless event.asset_changes.added.empty?
      puts "  assets changed: #{event.asset_changes.changed.join(", ")}" unless event.asset_changes.changed.empty?
      puts "  assets removed: #{event.asset_changes.removed.join(", ")}" unless event.asset_changes.removed.empty?
    end
    if update.asset_files_changed?
      puts "  asset files written: #{update.written_asset_paths.join(", ")}" unless update.written_asset_paths.empty?
      puts "  asset files removed: #{update.removed_asset_paths.join(", ")}" unless update.removed_asset_paths.empty?
    end
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

puts "Serving http://localhost:#{port}"
puts "Watching #{source_dir}"
puts "Mirroring assets to #{assets_dir}" if assets_dir
puts "Edit example/web/src/pages/page.haml, example/web/src/pages/page.css, or example/web/src/pages/dashboard/page.haml to see updates."

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
