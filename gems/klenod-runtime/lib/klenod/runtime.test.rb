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

  def test_runtime_require_does_not_load_build_or_plugin_dependencies
    script = <<~RUBY
      require "klenod/runtime"

      forbidden = {
        "Klenod::Build" => defined?(Klenod::Build),
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
      abort "missing backtrace rewriter" unless defined?(Klenod::Runtime::BacktraceRewriter)
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

  def test_runtime_gemspec_excludes_build_plugin_and_dev_files
    spec = Gem::Specification.load(File.expand_path("../../klenod-runtime.gemspec", __dir__))

    assert_includes(spec.files, "lib/klenod/runtime.rb")
    assert_includes(spec.files, "lib/klenod/runtime/source_map.rb")
    assert_includes(spec.files, "lib/klenod/runtime/backtrace_rewriter.rb")
    refute(spec.files.any? { |path| path.start_with?("lib/klenod/build/") })
    refute(spec.files.any? { |path| path.start_with?("lib/klenod/rack/") })
    refute(spec.files.any? { |path| path.end_with?(".test.rb") })
    refute(spec.dependencies.any? { |dependency| dependency.name == "rmagick" })
    refute(spec.dependencies.any? { |dependency| dependency.name == "syntax_tree-haml" })
  end
end
