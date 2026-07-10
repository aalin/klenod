# frozen_string_literal: true

require "fileutils"

require_relative "../../lib/klenod"

config = Klenod::Build::ConfigLoader.load(File.expand_path("klenod.config.rb", __dir__))
source_dir = config.source_path
output = config.output_path
assets_dir = config.assets_path

FileUtils.mkdir_p(File.dirname(output))

context = config.context
context.build(entrypoints: config.entrypoints, output: output, assets_dir: assets_dir)

bundle = Klenod::Runtime.load_bundle(output, source_root: source_dir)
exports = bundle.exports(config.entrypoints.fetch(0))
status, headers, body = exports.call(nil, bundle)

puts "Loaded bundle #{output}"
puts "Source root: #{bundle.source_root}"
puts "Entry module path: #{exports.module_path}"
puts "Status: #{status}"
puts "Content-Type: #{headers.fetch("content-type")}"
puts "Body includes Haml page: #{body.join.include?("<main")}"
puts "Assets:"

bundle.assets.each_key do |output_path|
  disk_path = File.join(assets_dir, output_path.delete_prefix("/"))
  puts "  - #{output_path} -> #{disk_path}"
end
