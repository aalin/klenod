# frozen_string_literal: true

require "bundler/setup"
require "klenod"

config = Klenod::Build::ConfigLoader.load(File.expand_path("klenod.config.rb", __dir__))
context = config.context
entry = context.entry(config.entrypoints.fetch(0))
entry.exports

puts "Loaded #{entry.id}"
puts "Source root: #{config.source_path}"
