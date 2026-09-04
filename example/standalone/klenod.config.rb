# frozen_string_literal: true

require "klenod"

source_dir "src"
entrypoint "main"
output "dist/release_report"

plugins [
  Klenod::Test::Plugin.new,
  Klenod::Build::Plugins::RubyPlugin.new,
  Klenod::Build::Plugins::JsonPlugin.new,
  Klenod::Build::Plugins::YamlPlugin.new,
  Klenod::Build::Plugins::TomlPlugin.new,
  Klenod::Build::Plugins::TextPlugin.new
]
