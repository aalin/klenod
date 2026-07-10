# frozen_string_literal: true

require_relative "../lib/klenod"

config = Klenod::Build::ConfigLoader.load(File.expand_path("klenod.config.rb", __dir__))
source_dir = config.source_path
assets_dir = ENV["ASSETS_DIR"] && File.expand_path(ENV.fetch("ASSETS_DIR"))
context = config.context
entry = context.entry(config.entrypoints.fetch(0))
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

  if update.failed?
    update.error_messages.each { |message| warn "  error in #{message}" }
  else
    if update.asset_files_changed?
      puts "  asset files written: #{update.written_asset_paths.join(", ")}"
      puts "  asset files removed: #{update.removed_asset_paths.join(", ")}"
    end
    status, _headers, body = update.entry.call(nil, context)
    puts "  status: #{status}"
    puts "  body includes Haml page: #{body.join.include?("<main")}"
  end
end

status, _headers, body = entry.call(nil, context)
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
