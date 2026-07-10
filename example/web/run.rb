# frozen_string_literal: true

require_relative "../../lib/klenod"

config = Klenod::Build::ConfigLoader.load(File.expand_path("klenod.config.rb", __dir__))
context = config.context
entry = context.entry(config.entrypoints.fetch(0))
status, headers, body = entry.call(nil, context)

puts "Loaded #{entry.id}"
puts "Status: #{status}"
puts "Content-Type: #{headers.fetch("content-type")}"
puts "Body includes Haml page: #{body.join.include?("<main")}"
puts "Graph modules:"

context.graph.records.each_key do |module_id|
  puts "  - #{module_id}"
end
