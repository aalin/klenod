# frozen_string_literal: true

require "bundler/setup"
require "minitest"
require "minitest/test"
require "rbconfig"

require "klenod"
require "klenod/test"

CONFIG_PATH = File.expand_path("klenod.config.rb", __dir__)

context = -> { Klenod::Build::ConfigLoader.load(CONFIG_PATH).context }
execute = lambda do |test_context, test_paths|
  test_paths.each do |path|
    exports = test_context.entry(path).exports
    Class.new(Minitest::Test) do
      include exports

      define_singleton_method(:name) { path }
    end
  end

  Minitest.run ? 0 : 1
end

exit Klenod::Test::Command.new(
  ARGV,
  context:,
  execute:,
  worker_command: [RbConfig.ruby, __FILE__]
).call
