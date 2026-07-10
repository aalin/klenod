# frozen_string_literal: true

require "minitest/autorun"
require "rbconfig"
require "open3"

require_relative "runtime"

module Klenod
  class RuntimeBoundaryTest < Minitest::Test
  end
end

class Klenod::RuntimeBoundaryTest
  def test_class_names_joins_clsx_style_values
    assert_equal(
      "base nested active 1",
      Klenod::Runtime.class_names(
        "base",
        nil,
        false,
        ["nested", nil],
        {active: true, hidden: false},
        1
      )
    )
    assert_nil(Klenod::Runtime.class_names(nil, false, []))
  end

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
          {}
        )
      bundle =
        Klenod::Runtime::Bundle.new(
          { "entry" => "entry.rb" },
          {
            "entry.rb" => Klenod::Runtime::ModuleSpec.new(
              "entry.rb",
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
      abort "bad asset" unless bundle.asset(asset.output_path).content_type == "text/css"
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
