# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"

require "klenod/runtime"
require_relative "application"

class Klenod::Build::CLI::Application::Test < Minitest::Test
  def test_build_gemspec_owns_build_cli_and_plugin_files
    spec = Gem::Specification.load(File.expand_path("../../../../klenod-build.gemspec", __dir__))

    assert_includes(spec.files, "lib/klenod/build.rb")
    assert_includes(spec.files, "lib/klenod/build/context.rb")
    assert_includes(spec.files, "lib/klenod/build/graphviz.rb")
    assert_includes(spec.files, "lib/klenod/build/plugins/haml_plugin.rb")
    assert_includes(spec.files, "lib/klenod/build/cli/application.rb")
    assert_includes(spec.files, "lib/klenod/build/watcher.rb")
    refute_includes(spec.files, "exe/klenod")
    refute_includes(spec.files, "lib/klenod.rb")
    refute(spec.files.any? { |path| path.end_with?(".test.rb") })
    assert(spec.dependencies.any? { |dependency| dependency.name == "klenod-runtime" })
    assert(spec.dependencies.any? { |dependency| dependency.name == "rmagick" })
    assert(spec.dependencies.any? { |dependency| dependency.name == "syntax_tree-haml" })
  end

  def test_build_command_writes_runtime_bundle
    Dir.mktmpdir do |dir|
      source_dir = "#{dir}/src"
      output = "#{dir}/dist/klenod.bundle"
      FileUtils.mkdir_p(source_dir)
      File.write("#{source_dir}/entry.rb", "VALUE = 42\n")
      File.write(
        "#{dir}/klenod.config.rb",
        <<~RUBY
          source_dir "src"
          entrypoint "entry"
          output "dist/klenod.bundle"
          plugins [
            Klenod::Build::Plugins::RubyPlugin.new
          ]
        RUBY
      )

      stdout = StringIO.new
      bundle = nil
      Dir.chdir(dir) do
        command = Klenod::Build::CLI::Application.new(["build"], output: stdout)
        bundle = command.call
      end
      loaded = Klenod::Runtime.load_bundle(output)

      assert_equal(42, loaded.exports("entry")::VALUE)
      assert_equal(["entry"], bundle.entrypoints.keys)
      assert_includes(stdout.string, "Built ")
      assert_includes(stdout.string, "Source root: ")
    end
  end

  def test_build_command_finds_config_in_parent_directory
    Dir.mktmpdir do |dir|
      source_dir = "#{dir}/app"
      output = "#{dir}/dist/config.bundle"
      nested = "#{source_dir}/pages"
      FileUtils.mkdir_p(nested)
      File.write("#{source_dir}/entry.rb", "VALUE = 42\n")
      File.write(
        "#{dir}/klenod.config.rb",
        <<~RUBY
          source_dir "app"
          entrypoint "entry"
          output "dist/config.bundle"
          plugins [
            Klenod::Build::Plugins::RubyPlugin.new
          ]
        RUBY
      )

      stdout = StringIO.new
      Dir.chdir(nested) do
        command = Klenod::Build::CLI::Application.new(["build"], output: stdout)
        command.call
      end
      loaded = Klenod::Runtime.load_bundle(output)

      assert_equal(42, loaded.exports("entry")::VALUE)
      assert_includes(stdout.string, "Built ")
    end
  end

  def test_build_command_writes_executable_bundle
    Dir.mktmpdir do |dir|
      source_dir = "#{dir}/src"
      output = "#{dir}/dist/app"
      result_path = "#{dir}/result.txt"
      FileUtils.mkdir_p(source_dir)
      File.write("#{source_dir}/entry.rb", "File.binwrite(#{result_path.inspect}, \"ran\")\n")
      File.write(
        "#{dir}/klenod.config.rb",
        <<~RUBY
          source_dir "src"
          entrypoint "entry"
          output "dist/app"
          plugins [
            Klenod::Build::Plugins::RubyPlugin.new
          ]
        RUBY
      )

      stdout = StringIO.new
      bundle = nil
      Dir.chdir(dir) do
        command = Klenod::Build::CLI::Application.new(["build", "--executable"], output: stdout)
        bundle = command.call
      end
      loaded = Klenod::Runtime.load_executable_bundle(output)
      ruby_stdout, ruby_stderr, status =
        Open3.capture3(
          RbConfig.ruby,
          "-I#{File.expand_path("../../..", __dir__)}",
          "-I#{File.expand_path("../../../../../klenod-runtime/lib", __dir__)}",
          output
        )

      assert_equal(["entry"], bundle.entrypoints.keys)
      assert_equal(bundle.modules.keys.sort, loaded.modules.keys.sort)
      assert(status.success?, "stdout:\n#{ruby_stdout}\nstderr:\n#{ruby_stderr}")
      assert_equal("ran", File.binread(result_path))
      assert_includes(stdout.string, "Built executable bundle ")
      assert(File.executable?(output), "Expected #{output} to be executable")
    end
  end

  def test_graph_command_exports_runtime_bundle_dot
    Dir.mktmpdir do |dir|
      output = "#{dir}/klenod.bundle"
      bundle =
        Klenod::Runtime::Bundle.new(
          {"entry" => "entry.rb"},
          {
            "entry.rb" => Klenod::Runtime::ModuleSpec.new(
              "entry.rb",
              "entry.rb",
              "",
              {"dep" => Klenod::Runtime::ImportSpec.new("dep.css", nil, false)},
              nil,
              0,
              nil
            ),
            "dep.css" => Klenod::Runtime::ModuleSpec.new(
              "dep.css",
              "dep.css",
              "",
              {},
              nil,
              0,
              nil
            )
          },
          {
            "/assets/dep.123.css" => Klenod::Runtime::AssetSpec.new(
              "dep.css",
              "123",
              "/assets/dep.123.css",
              "text/css",
              {type: :stylesheet}
            )
          },
          source_root: "#{dir}/src"
        )
      File.binwrite(output, Klenod::Runtime::BundleFormat.dump(bundle))

      stdout = StringIO.new
      command = Klenod::Build::CLI::Application.new(["graph", output], output: stdout)

      dot = command.call

      assert_equal(dot, stdout.string)
      assert_includes(stdout.string, "digraph klenod")
      assert_includes(stdout.string, "label=\"entry.rb\\nrb entrypoint\"")
      assert_includes(stdout.string, "label=\"lazy\"")
      assert_includes(stdout.string, "label=\"/assets/dep.123.css\\ntext/css\"")
    end
  end

  def test_graph_command_can_hide_assets
    Dir.mktmpdir do |dir|
      output = "#{dir}/klenod.bundle"
      bundle =
        Klenod::Runtime::Bundle.new(
          {"entry" => "entry.rb"},
          {
            "entry.rb" => Klenod::Runtime::ModuleSpec.new(
              "entry.rb",
              "entry.rb",
              "",
              {},
              nil,
              0,
              nil
            )
          },
          {
            "/assets/entry.123.js" => Klenod::Runtime::AssetSpec.new(
              "entry.rb",
              "123",
              "/assets/entry.123.js",
              "text/javascript",
              {}
            )
          }
        )
      File.binwrite(output, Klenod::Runtime::BundleFormat.dump(bundle))

      stdout = StringIO.new
      command = Klenod::Build::CLI::Application.new(["graph", "--no-assets", output], output: stdout)

      command.call

      refute_includes(stdout.string, "/assets/entry.123.js")
    end
  end

  def test_version_option_prints_version
    stdout = StringIO.new
    command = Klenod::Build::CLI::Application.new(["--version"], output: stdout)

    command.call

    assert_equal("#{Klenod::Build::VERSION}\n", stdout.string)
  end
end
