# frozen_string_literal: true

require "klenod"

source_dir "src"
entrypoint "main"
output "dist/release_report"

plugins [
  Klenod::Build::Plugins::RubyPlugin::Plugin.new,
  Klenod::Build::Plugins::JsonPlugin::Plugin.new,
  Klenod::Build::Plugins::YamlPlugin::Plugin.new,
  Klenod::Build::Plugins::TomlPlugin::Plugin.new,
  Klenod::Build::Plugins::TextPlugin::Plugin.new
]
