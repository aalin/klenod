# frozen_string_literal: true

require_relative "framework"
require_relative "../../lib/klenod"

source_dir "src"
entrypoint "pages/server"
output "dist/klenod.bundle"
assets_dir "dist/public"

plugins [
  Klenod::Build::Plugins::RubyPlugin.new,
  Klenod::Build::Plugins::IntlPlugin.new,
  Klenod::Build::Plugins::HamlPlugin.new(
    component_base_class: "Example::Component",
    factory: "Example::H"
  ),
  Klenod::Build::Plugins::CssPlugin.new,
  Klenod::Build::Plugins::ImagePlugin.new,
  Klenod::Build::Plugins::JsonPlugin.new,
  Klenod::Build::Plugins::YamlPlugin.new,
  Klenod::Build::Plugins::TomlPlugin.new,
  Klenod::Build::Plugins::TextPlugin.new,
  Klenod::Build::Plugins::RouterPlugin.new
]
