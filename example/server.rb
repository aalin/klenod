# frozen_string_literal: true

require "async"
require "async/http"
require "protocol/http/response"

require_relative "../lib/klenod"

source_dir = File.expand_path("src", __dir__)
entrypoint = "pages/server"
port = Integer(ENV.fetch("PORT", "9292"))
endpoint = Async::HTTP::Endpoint.parse("http://localhost:#{port}")

context = Klenod::Build::Context.new(source_dir: source_dir)
record = context.load(entrypoint)
watcher = Klenod::Dev::Watcher.new(source_dir: source_dir, context: context)
page = context.graph.mods.fetch(record.id).const_get(:Exports)

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
    puts "Update ##{event.graph_version}: dependency tree updated"
  end
end

puts "Serving http://localhost:#{port}"
puts "Watching #{source_dir}"
puts "Edit example/src/pages/server.rb or example/src/shared.rb to see updates."

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
            [asset.bytes]
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
