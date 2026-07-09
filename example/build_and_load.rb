# frozen_string_literal: true

require "fileutils"

require_relative "klenod_context"

source_dir = File.expand_path("src", __dir__)
output = File.expand_path("dist/klenod.bundle", __dir__)
assets_dir = File.expand_path("dist/public", __dir__)

FileUtils.mkdir_p(File.dirname(output))

context = Example.build_context(source_dir: source_dir)
context.build(entrypoints: ["pages/server"], output: output, assets_dir: assets_dir)

bundle = Klenod::Runtime.load_bundle(output)
exports = bundle.exports("pages/server")
status, headers, body = exports.call(nil, bundle)

puts "Loaded bundle #{output}"
puts "Status: #{status}"
puts "Content-Type: #{headers.fetch("content-type")}"
puts "Body includes Haml page: #{body.join.include?("<main")}"
puts "Assets:"

bundle.assets.each_key do |output_path|
  disk_path = File.join(assets_dir, output_path.delete_prefix("/"))
  puts "  - #{output_path} -> #{disk_path}"
end
