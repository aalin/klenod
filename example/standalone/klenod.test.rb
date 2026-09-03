# frozen_string_literal: true

require "minitest"
require "minitest/test"

context do
  path = File.expand_path("klenod.config.rb", __dir__)
  Klenod::Build::ConfigLoader.load(path).context
end

execute do |test_context, test_paths|
  test_paths.each do |path|
    exports = test_context.entry(path).exports
    Class.new(Minitest::Test) do
      include exports

      define_singleton_method(:name) { path }
    end
  end

  Minitest.run ? 0 : 1
end
