# frozen_string_literal: true

require "minitest/autorun"

require_relative "../plugins"

module Klenod
  module Build
    module Plugins
      class NamespacesTest < Minitest::Test
        def test_plugin_namespaces_expose_plugin_classes
          assert_operator RubyPlugin::Plugin.new, :is_a?, Klenod::Build::Plugin
          assert_operator IntlPlugin::Plugin.new, :is_a?, Klenod::Build::Plugin
          assert_operator HamlPlugin::Plugin.new, :is_a?, Klenod::Build::Plugin
          assert_operator MarkdownPlugin::Plugin.new, :is_a?, Klenod::Build::Plugin
          assert_operator GemImportPlugin::Plugin.new, :is_a?, Klenod::Build::Plugin
          assert_operator CssPlugin::Plugin.new, :is_a?, Klenod::Build::Plugin
          assert_operator JavaScriptPlugin::Plugin.new, :is_a?, Klenod::Build::Plugin
          assert_operator GoogleFontsPlugin::Plugin.new, :is_a?, Klenod::Build::Plugin
          assert_operator SvgPlugin::Plugin.new, :is_a?, Klenod::Build::Plugin
          assert_operator ImagePlugin::Plugin.new, :is_a?, Klenod::Build::Plugin
          assert_operator DataPlugin::Plugin.new, :is_a?, Klenod::Build::Plugin
          assert_operator RouterPlugin::Plugin.new, :is_a?, Klenod::Build::Plugin
        end

        def test_data_format_namespaces_expose_plugin_classes
          assert_operator JsonPlugin::Plugin.new, :is_a?, DataPlugin::Plugin
          assert_operator YamlPlugin::Plugin.new, :is_a?, DataPlugin::Plugin
          assert_operator TomlPlugin::Plugin.new, :is_a?, DataPlugin::Plugin
          assert_operator TextPlugin::Plugin.new, :is_a?, DataPlugin::Plugin
        end
      end
    end
  end
end
