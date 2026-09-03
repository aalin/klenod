# frozen_string_literal: true

require "minitest"
require "minitest/test"

require_relative "component_helpers"
require_relative "minitest_reporter"

module Example
  module Testing
    class MinitestAdapter
      def register(path, exports)
        ComponentTestHelpers::FRAMEWORK_CONSTANTS.each do |name, value|
          exports.const_set(name, value) unless exports.const_defined?(name, false)
        end

        Class.new(Minitest::Test) do
          include ComponentTestHelpers
          include exports

          define_singleton_method(:name) { path }
        end
      end

      def run(arguments = [])
        Minitest.register_plugin(MinitestReporterPlugin) unless Minitest.extensions.include?(MinitestReporterPlugin)
        Minitest.run(arguments)
      end
    end
  end
end
