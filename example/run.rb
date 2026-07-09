# frozen_string_literal: true

require_relative "klenod_context"

source_dir = File.expand_path("src", __dir__)
context = Example.build_context(source_dir: source_dir)
entry = context.entry("pages/server")
exports = entry.exports
status, headers, body = exports.call(nil, context)

puts "Loaded #{entry.id}"
puts "Status: #{status}"
puts "Content-Type: #{headers.fetch("content-type")}"
puts "Body includes Haml page: #{body.join.include?("<main")}"
puts "Graph modules:"

context.graph.records.each_key do |module_id|
  puts "  - #{module_id}"
end
