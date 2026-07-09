# frozen_string_literal: true

require "async"
require "async/http"
require "protocol/http/response"

require_relative "klenod_context"

source_dir = File.expand_path("src", __dir__)
entrypoint = "pages/server"
port = Integer(ENV.fetch("PORT", "9292"))
assets_dir = ENV["ASSETS_DIR"] && File.expand_path(ENV.fetch("ASSETS_DIR"))
endpoint = Async::HTTP::Endpoint.parse("http://localhost:#{port}")

context = Example.build_context(source_dir: source_dir)
entry = context.entry(entrypoint)
watcher = Klenod::Dev::Watcher.new(source_dir: source_dir, context: context)
context.write_assets(assets_dir) if assets_dir

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

puts "Serving http://localhost:#{port}"
puts "Watching #{source_dir}"
puts "Mirroring assets to #{assets_dir}" if assets_dir
puts "Edit example/src/pages/page.haml, example/src/pages/page.css, or example/src/shared.rb to see updates."

begin
  watcher.start

  Async do
    server =
      Async::HTTP::Server.for(endpoint) do |request|
        if request.path.start_with?("/assets/")
          asset = context.asset(request.path)
          Protocol::HTTP::Response[
            200,
            {"content-type" => asset.content_type},
            [context.asset_bytes(request.path, assets_dir: assets_dir)]
          ]
        else
          status, headers, body = entry.call(request, context)
          Protocol::HTTP::Response[status, headers, body]
        end
      rescue KeyError
        Protocol::HTTP::Response[
          404,
          {"content-type" => "text/plain"},
          ["Asset not found\n"]
        ]
      rescue => e
        warn "#{e.class}: #{e.message}"
        Protocol::HTTP::Response[
          500,
          {"content-type" => "text/plain"},
          ["#{e.class}: #{e.message}\n"]
        ]
      end

    server.run.wait
  end
ensure
  watcher&.stop
end
