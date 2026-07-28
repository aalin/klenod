# frozen_string_literal: true

require "minitest/autorun"
require_relative "haml_plugin/errors.test"
require_relative "haml_plugin/parser.test"
require_relative "haml_plugin/helper_source.test"
require_relative "haml_plugin/fixtures.test"
require_relative "haml_plugin/transformer/ruby_builder.test"
require_relative "haml_plugin/transformer.test"
require_relative "haml_plugin/evaluation.test"
require_relative "haml_plugin/backtrace.test"
require_relative "haml_plugin/companions.test"

module Klenod
  module Build
    module Plugins
      class HamlPluginSmokeTest < Minitest::Test
        def test_haml_plugin_can_be_required_and_constructed_with_options
          plugin =
            HamlPlugin.new(
              component_base_class: "Object",
              factory: "Object",
              global_variables: "@__props",
              cache_static_subtrees: true
            )

          assert_instance_of HamlPlugin, plugin
        end
      end
    end
  end
end
