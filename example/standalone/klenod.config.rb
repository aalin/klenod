# frozen_string_literal: true

require_relative "../../lib/klenod"

source_dir "src"
entrypoint "main"
output "dist/release_report"

plugins [
  Klenod::Build::Plugins::RubyPlugin.new,
  Klenod::Build::Plugins::JsonPlugin.new,
  Klenod::Build::Plugins::YamlPlugin.new,
  Klenod::Build::Plugins::TomlPlugin.new,
  Klenod::Build::Plugins::TextPlugin.new
]
