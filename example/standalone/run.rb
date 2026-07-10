# frozen_string_literal: true

require_relative "../../lib/klenod"

config = Klenod::Build::ConfigLoader.load(File.expand_path("klenod.config.rb", __dir__))
context = config.context
entry = context.entry(config.entrypoints.fetch(0))
entry.exports::Default.call

puts "Loaded #{entry.id}"
puts "Source root: #{config.source_path}"
