# frozen_string_literal: true

require "minitest/autorun"

require_relative "../plugins"

module Klenod
  module Build
    module Plugins
      class NamespacesTest < Minitest::Test
        def test_plugin_namespaces_expose_plugin_classes
          assert_operator RubyPlugin.new, :is_a?, Klenod::Build::Plugin
          assert_operator IntlPlugin.new, :is_a?, Klenod::Build::Plugin
          assert_operator HamlPlugin.new, :is_a?, Klenod::Build::Plugin
          assert_operator MarkdownPlugin.new, :is_a?, Klenod::Build::Plugin
          assert_operator GemImportPlugin.new, :is_a?, Klenod::Build::Plugin
          assert_operator GoogleFontsPlugin.new, :is_a?, Klenod::Build::Plugin
          assert_operator SvgPlugin.new, :is_a?, Klenod::Build::Plugin
          assert_operator ImagePlugin.new, :is_a?, Klenod::Build::Plugin
          assert_operator DataPlugin.new, :is_a?, Klenod::Build::Plugin
          assert_operator RouterPlugin.new, :is_a?, Klenod::Build::Plugin
        end

        def test_data_format_namespaces_expose_plugin_classes
          assert_operator JsonPlugin.new, :is_a?, DataPlugin::Plugin
          assert_operator YamlPlugin.new, :is_a?, DataPlugin::Plugin
          assert_operator TomlPlugin.new, :is_a?, DataPlugin::Plugin
          assert_operator TextPlugin.new, :is_a?, DataPlugin::Plugin
        end
      end
    end
  end
end
