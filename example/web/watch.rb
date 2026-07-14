# frozen_string_literal: true

require_relative "../../lib/klenod"
require_relative "dev/update_logger"
require_relative "server/errors"
require_relative "server/formatting"

config = Klenod::Build::ConfigLoader.load(File.expand_path("klenod.config.rb", __dir__))
source_dir = config.source_path
assets_dir = ENV["ASSETS_DIR"] && File.expand_path(ENV.fetch("ASSETS_DIR"))
context = config.context
entry = context.entry(config.entrypoints.fetch(0))
watcher = Klenod::Dev::Watcher.new(source_dir: source_dir, context: context)
write_result = assets_dir && context.write_assets(assets_dir)
update_logger = Example::UpdateLogger.new(source_dir: source_dir)

context.on_update do |event|
  start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  update = context.apply_update(event, entry: entry, assets_dir: assets_dir)

  update_logger.log(event: event, update: update, duration: Example::ServerFormatting.duration_ms(start_time)) do |module_id, error|
    Example::ServerErrors.format_update_error(module_id, error, context)
  end

  unless update.failed?
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

begin
  watcher.start
  sleep
ensure
  watcher&.stop
end
