# frozen_string_literal: true

require_relative "klenod_context"

source_dir = File.expand_path("src", __dir__)
context = Example.build_context(source_dir: source_dir)
record = context.load("pages/server")
watcher = Klenod::Dev::Watcher.new(source_dir: source_dir, context: context)

context.on_update do |event|
  result = event.result

  puts "Update ##{event.graph_version}"
  puts "  changed: #{result.changed_module_ids.join(", ")}"
  puts "  removed: #{result.removed_module_ids.join(", ")}"
  puts "  reloaded: #{result.reloaded_module_ids.join(", ")}"
  puts "  reevaluated: #{result.reevaluated_module_ids.join(", ")}"

  if result.errors.any?
    result.errors.each do |module_id, error|
      warn "  error in #{module_id}: #{error.class}: #{error.message}"
    end
  else
    exports = context.graph.mods.fetch(record.id).const_get(:Exports)
    status, _headers, body = exports.call(nil, context)
    puts "  status: #{status}"
    puts "  body includes Haml page: #{body.join.include?("<main")}"
  end
end

exports = context.graph.mods.fetch(record.id).const_get(:Exports)
status, _headers, body = exports.call(nil, context)
puts "Watching #{source_dir}"
puts "Initial status: #{status}"
puts "Initial body includes Haml page: #{body.join.include?("<main")}"
puts "Edit example/src/pages/page.haml, example/src/pages/page.css, or example/src/shared.rb to see an update."

begin
  watcher.start
  sleep
ensure
  watcher&.stop
end
