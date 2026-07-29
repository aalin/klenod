# frozen_string_literal: true

require "minitest/autorun"
require_relative "haml/errors.test"
require_relative "haml/parser.test"
require_relative "haml/helper_source.test"
require_relative "haml/fixtures.test"
require_relative "haml/transformer/ruby_builder.test"
require_relative "haml/transformer.test"
require_relative "haml/evaluation.test"
require_relative "haml/backtrace.test"
require_relative "haml/companions.test"

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
