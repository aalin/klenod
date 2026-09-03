# frozen_string_literal: true

require "minitest"
require "minitest/test"

require_relative "component_helpers"

module Example
  class MinitestAdapter
    def register(path, exports)
      Class.new(Minitest::Test) do
        include ComponentTestHelpers
        include exports

        define_singleton_method(:name) { path }
      end
    end

    def run(arguments = [])
      Minitest.run(arguments)
    end
  end
end
