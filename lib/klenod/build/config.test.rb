# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"

require_relative "context"

class Klenod::Build::Config::Test < Minitest::Test
  def test_loads_ruby_config_file
    Dir.mktmpdir do |dir|
      path = "#{dir}/klenod.rb"
      File.write(
        path,
        <<~RUBY
          source_dir "app"
          entrypoint "pages/server"
          output "dist/app.bundle"
          assets_dir "public"
          mode :build
          plugins [
            Klenod::Build::Plugins::RubyPlugin.new
          ]
        RUBY
      )

      config = Klenod::Build::ConfigLoader.load(path)

      assert_equal("app", config.source_dir)
      assert_equal(["pages/server"], config.entrypoints)
      assert_equal("dist/app.bundle", config.output)
      assert_equal("public", config.assets_dir)
      assert_equal(:build, config.mode)
      assert_equal([Klenod::Build::Plugins::RubyPlugin], config.plugins.map(&:class))
      assert_equal(dir, config.base_dir)
    end
  end
end
