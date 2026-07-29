# frozen_string_literal: true

require "minitest/autorun"

require_relative "../plugins"

module Klenod
  module Build
    module Plugins
      class NamespacesTest < Minitest::Test
        def test_plugin_aliases_point_to_namespaced_plugin_classes
          assert_same Ruby::Plugin, RubyPlugin
          assert_same Intl::Plugin, IntlPlugin
          assert_same Haml::Plugin, HamlPlugin
          assert_same Markdown::Plugin, MarkdownPlugin
          assert_same Css::Plugin, CssPlugin
          assert_same GoogleFonts::Plugin, GoogleFontsPlugin
          assert_same Svg::Plugin, SvgPlugin
          assert_same Image::Plugin, ImagePlugin
          assert_same Data::Plugin, DataPlugin
          assert_same Router::Plugin, RouterPlugin
        end

        def test_data_format_aliases_point_to_namespaced_plugins
          assert_same Data::JsonPlugin, JsonPlugin
          assert_same Data::YamlPlugin, YamlPlugin
          assert_same Data::TomlPlugin, TomlPlugin
          assert_same Data::TextPlugin, TextPlugin
        end
      end
    end
  end
end
