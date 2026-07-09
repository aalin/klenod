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
record = context.load(entrypoint)
watcher = Klenod::Dev::Watcher.new(source_dir: source_dir, context: context)
page = context.graph.mods.fetch(record.id).const_get(:Exports)
context.write_assets(assets_dir) if assets_dir

context.on_update do |event|
  result = event.result

  if result.errors.any?
    warn "Update ##{event.graph_version} failed"
    result.errors.each do |module_id, error|
      warn "  #{module_id}: #{error.class}: #{error.message}"
    end
  else
    record = context.graph.records.fetch(record.id)
    page = context.graph.mods.fetch(record.id).const_get(:Exports)
    asset_write_result = assets_dir && context.write_asset_updates(event.asset_updates, assets_dir: assets_dir)
    puts "Update ##{event.graph_version}: dependency tree updated"
    unless event.asset_changes.empty?
      puts "  assets added: #{event.asset_changes.added.join(", ")}" unless event.asset_changes.added.empty?
      puts "  assets changed: #{event.asset_changes.changed.join(", ")}" unless event.asset_changes.changed.empty?
      puts "  assets removed: #{event.asset_changes.removed.join(", ")}" unless event.asset_changes.removed.empty?
    end
    if asset_write_result && !asset_write_result.empty?
      puts "  asset files written: #{asset_write_result.written_paths.join(", ")}" unless asset_write_result.written_paths.empty?
      puts "  asset files removed: #{asset_write_result.removed_paths.join(", ")}" unless asset_write_result.removed_paths.empty?
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
          bytes =
            if assets_dir
              File.binread(File.join(assets_dir, asset.output_path.delete_prefix("/")))
            else
              asset.bytes
            end
          Protocol::HTTP::Response[
            200,
            {"content-type" => asset.content_type},
            [bytes]
          ]
        else
          status, headers, body = page.call(request, context)
          Protocol::HTTP::Response[status, headers, body]
        end
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
