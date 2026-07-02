# frozen_string_literal: true

require "fileutils"

require_relative "../lib/klenod"

source_dir = File.expand_path("src", __dir__)
output = File.expand_path("dist/klenod.bundle", __dir__)

FileUtils.mkdir_p(File.dirname(output))

context = Klenod::Build::Context.new(source_dir: source_dir)
context.build(entrypoints: ["pages/home"], output: output)

bundle = Klenod::Runtime.load_bundle(output)
mod = bundle.load("pages/home")
exports = mod.const_get(:Exports)

puts "Loaded bundle #{output}"
puts "Title: #{exports::TITLE}"
puts "Message: #{exports::MESSAGE}"
