# frozen_string_literal: true

require_relative "framework"
require_relative "../lib/klenod"

module Example
  def self.build_context(source_dir:)
    Klenod::Build::Context.new(
      source_dir: source_dir,
      plugins: [
        Klenod::Build::Plugins::RubyPlugin.new,
        Klenod::Build::Plugins::IntlPlugin.new,
        Klenod::Build::Plugins::HamlPlugin.new(
          component_base_class: "Example::Component",
          factory: "Example::H"
        ),
        Klenod::Build::Plugins::CssPlugin.new,
        Klenod::Build::Plugins::ImagePlugin.new
      ]
    )
  end
end
