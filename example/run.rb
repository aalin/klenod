# frozen_string_literal: true

require_relative "../lib/klenod"

source_dir = File.expand_path("src", __dir__)
context = Klenod::Build::Context.new(source_dir: source_dir)
record = context.load("pages/home")
mod = context.graph.mods.fetch(record.id)
exports = mod.const_get(:Exports)

puts "Loaded #{record.id}"
puts "Title: #{exports::TITLE}"
puts "Message: #{exports::MESSAGE}"
puts "Title class: #{exports::TITLE_CLASS}"
puts "Graph modules:"

context.graph.records.each_key do |module_id|
  puts "  - #{module_id}"
end
