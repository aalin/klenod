# frozen_string_literal: true

require "minitest/autorun"
require "rbconfig"
require "open3"

module Klenod
  class RuntimeBoundaryTest < Minitest::Test
  end
end

class Klenod::RuntimeBoundaryTest
  def test_runtime_require_does_not_load_build_dev_or_plugin_dependencies
    script = <<~RUBY
      require "klenod/runtime"

      forbidden = {
        "Klenod::Build" => defined?(Klenod::Build),
        "Klenod::Dev" => defined?(Klenod::Dev),
        "Listen" => defined?(Listen),
        "SyntaxTree" => defined?(SyntaxTree),
        "Mayu::CSS" => defined?(Mayu::CSS),
        "TomlRB" => defined?(TomlRB)
      }.compact

      abort forbidden.inspect unless forbidden.empty?

      asset =
        Klenod::Runtime::AssetSpec.new(
          "styles/home.css",
          "abc123",
          "/assets/home.abc123.css",
          "text/css",
          ".title{}",
          {}
        )
      bundle =
        Klenod::Runtime::Bundle.new(
          { "entry" => "entry.rb" },
          {
            "entry.rb" => Klenod::Runtime::ModuleSpec.new(
              "entry.rb",
              "VALUE = 1",
              {},
              nil,
              0,
              Klenod::Runtime::Mod.constant_name_for("entry.rb")
            )
          },
          { asset.output_path => asset }
        )

      abort "bad module" unless bundle.load("entry").const_get(:Exports)::VALUE == 1
      abort "bad asset" unless bundle.asset(asset.output_path).bytes == ".title{}"
    RUBY

    stdout, stderr, status =
      Open3.capture3(
        RbConfig.ruby,
        "-I#{File.expand_path("..", __dir__)}",
        "-e",
        script
      )

    assert(status.success?, "stdout:\n#{stdout}\nstderr:\n#{stderr}")
  end
end
