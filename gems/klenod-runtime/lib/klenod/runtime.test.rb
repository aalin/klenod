# frozen_string_literal: true

require "minitest/autorun"
require "rbconfig"
require "open3"
require "stringio"

require_relative "runtime"

module Klenod
  class RuntimeBoundaryTest < Minitest::Test
  end
end

class Klenod::RuntimeBoundaryTest
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

  def test_load_bundle_in_box_requires_ruby_box
    skip "Ruby::Box is enabled for this process" if defined?(Ruby::Box) && Ruby::Box.enabled?

    error = assert_raises(RuntimeError) do
      Klenod::Runtime.load_bundle_in_box(StringIO.new("unused"))
    end

    assert_includes(error.message, "RUBY_BOX=1")
  end

  def test_load_bundle_in_box_evaluates_modules_inside_box
    script = <<~RUBY
      require "stringio"
      require "klenod/runtime"

      constant_name = Klenod::Runtime::Mod.constant_name_for("entry.rb")
      bundle =
        Klenod::Runtime::Bundle.new(
          { "entry" => "entry.rb" },
          {
            "entry.rb" => Klenod::Runtime::ModuleSpec.new(
              "entry.rb",
              "entry.rb",
              "VALUE = 42\\nBOX_ID = Ruby::Box.current.object_id",
              {},
              nil,
              0,
              constant_name
            )
          },
          {}
        )

      payload = Klenod::Runtime::BundleFormat.dump(bundle)
      loaded = Klenod::Runtime.load_bundle_in_box(StringIO.new(payload))
      exports = loaded.exports("entry")

      abort "bad value" unless exports::VALUE == 42
      abort "module evaluated in main box" if exports::BOX_ID == Ruby::Box.current.object_id
      abort "generated constant leaked into main runtime" if Klenod::Runtime::Generated.const_defined?(constant_name, false)
    RUBY

    stdout, stderr, status =
      Open3.capture3(
        {
          "RUBY_BOX" => "1",
          "HOME" => ENV.fetch("HOME", nil),
          "PATH" => ENV.fetch("PATH", nil)
        },
        RbConfig.ruby,
        "-I#{File.expand_path("..", __dir__)}",
        "-e",
        script,
        unsetenv_others: true
      )

    assert(status.success?, "stdout:\n#{stdout}\nstderr:\n#{stderr}")
  end

  def test_load_bundle_in_box_reuses_prepared_box
    script = <<~RUBY
      require "stringio"
      require "klenod/runtime"

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
          {}
        )

      payload = Klenod::Runtime::BundleFormat.dump(bundle)
      box = Ruby::Box.new
      box.require(File.expand_path("runtime.rb", #{__dir__.inspect}))

      def box.require(...)
        raise "unexpected box require"
      end

      loaded = Klenod::Runtime.load_bundle_in_box(StringIO.new(payload), box: box)
      abort "bad value" unless loaded.exports("entry")::VALUE == 1
    RUBY

    stdout, stderr, status =
      Open3.capture3(
        {
          "RUBY_BOX" => "1",
          "HOME" => ENV.fetch("HOME", nil),
          "PATH" => ENV.fetch("PATH", nil)
        },
        RbConfig.ruby,
        "-I#{File.expand_path("..", __dir__)}",
        "-e",
        script,
        unsetenv_others: true
      )

    assert(status.success?, "stdout:\n#{stdout}\nstderr:\n#{stderr}")
  end

  def test_prepare_box_loads_runtime_once
    script = <<~RUBY
      require "klenod/runtime"

      box = Ruby::Box.new
      prepared = Klenod::Runtime.prepare_box(box)

      abort "different box" unless prepared.equal?(box)
      abort "runtime missing" unless box.eval("defined?(Klenod::Runtime)")

      def box.require(...)
        raise "unexpected box require"
      end

      Klenod::Runtime.prepare_box(box)
    RUBY

    stdout, stderr, status =
      Open3.capture3(
        {
          "RUBY_BOX" => "1",
          "HOME" => ENV.fetch("HOME", nil),
          "PATH" => ENV.fetch("PATH", nil)
        },
        RbConfig.ruby,
        "-I#{File.expand_path("..", __dir__)}",
        "-e",
        script,
        unsetenv_others: true
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

  def test_bundle_asset_url_joins_a_normalized_base
    asset = Klenod::Runtime::AssetSpec.new("logo.png", "hash", "/assets/logo.hash.png", "image/png", {})
    bundle = Klenod::Runtime::Bundle.new({}, {}, {asset.output_path => asset}, base: "https://cdn.example.test/assets")
    loaded = Klenod::Runtime::BundleFormat.load_bytes(Klenod::Runtime::BundleFormat.dump(bundle))

    assert_equal("https://cdn.example.test/assets/logo.hash.png", bundle.asset_url(asset))
    assert_equal(bundle.base, loaded.base)
    assert_equal(bundle.asset_url(asset), loaded.asset_url(asset))
  end
end
