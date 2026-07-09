# frozen_string_literal: true

require_relative "klenod_context"

source_dir = File.expand_path("src", __dir__)
assets_dir = ENV["ASSETS_DIR"] && File.expand_path(ENV.fetch("ASSETS_DIR"))
context = Example.build_context(source_dir: source_dir)
entry = context.entry("pages/server")
watcher = Klenod::Dev::Watcher.new(source_dir: source_dir, context: context)
write_result = assets_dir && context.write_assets(assets_dir)

context.on_update do |event|
  result = event.result
  update = context.apply_update(event, entry: entry, assets_dir: assets_dir)

  puts "Update ##{event.graph_version}"
  puts "  changed: #{result.changed_module_ids.join(", ")}"
  puts "  removed: #{result.removed_module_ids.join(", ")}"
  puts "  reloaded: #{result.reloaded_module_ids.join(", ")}"
  puts "  reevaluated: #{result.reevaluated_module_ids.join(", ")}"
  puts "  assets added: #{event.asset_changes.added.join(", ")}"
  puts "  assets changed: #{event.asset_changes.changed.join(", ")}"
  puts "  assets removed: #{event.asset_changes.removed.join(", ")}"

  if update.errors.any?
    update.errors.each do |module_id, error|
      warn "  error in #{module_id}: #{error.class}: #{error.message}"
    end
  else
    if update.asset_write_result && !update.asset_write_result.empty?
      puts "  asset files written: #{update.asset_write_result.written_paths.join(", ")}"
      puts "  asset files removed: #{update.asset_write_result.removed_paths.join(", ")}"
    end
    exports = update.entry.exports
    status, _headers, body = exports.call(nil, context)
    puts "  status: #{status}"
    puts "  body includes Haml page: #{body.join.include?("<main")}"
  end
end

exports = entry.exports
status, _headers, body = exports.call(nil, context)
puts "Watching #{source_dir}"
puts "Mirroring assets to #{assets_dir}" if assets_dir
puts "Initial asset files written: #{write_result.written_paths.length}" if write_result
puts "Initial status: #{status}"
puts "Initial body includes Haml page: #{body.join.include?("<main")}"
puts "Edit example/src/pages/page.haml, example/src/pages/page.css, or example/src/shared.rb to see an update."

begin
  watcher.start
  sleep
ensure
  watcher&.stop
end
