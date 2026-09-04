# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "stringio"
require "tmpdir"

require_relative "runner"

class Klenod::Test::Runner::Test < Minitest::Test
  Status = Data.define(:exitstatus) do
    def success?
      exitstatus.zero?
    end
  end

  class FakeProcess
    attr_reader :calls

    def initialize(status: 0)
      @status = status
      @calls = []
    end

    def spawn(*arguments)
      calls << arguments
      Status.new(@status)
    end
  end

  class InspectableRunner < Klenod::Test::Runner
    def initialize(*arguments, watcher: nil, wait: nil, **options)
      @watcher = watcher
      @wait = wait
      super(*arguments, **options)
    end

    private

    attr_reader :watcher, :wait

    def build_watcher(context)
      watcher || super
    end

    def wait_for_changes
      wait ? wait.call : super
    end
  end

  def test_worker_executes_selected_paths_with_a_fresh_context
    context = Object.new
    received = nil
    runner = runner(
      worker_paths: ["a.test.rb", "b.test.rb"],
      context: -> { context },
      execute: lambda do |*arguments|
        received = arguments
        3
      end
    )

    status = runner.call

    assert_equal(3, status)
    assert_equal([context, ["a.test.rb", "b.test.rb"]], received)
  end

  def test_run_discovers_tests_in_stable_order_and_spawns_a_worker
    with_context(
      "z.test.rb" => "def test_z; end\n",
      "a.test.rb" => "def test_a; end\n"
    ) do |context|
      process = FakeProcess.new
      output = StringIO.new
      runner = runner(watch: false, context: -> { context }, output:, process:)

      status = runner.call

      assert_equal(0, status)
      assert_equal(
        [[RbConfig.ruby, "/app/test", "--worker", "--", "a.test.rb", "z.test.rb"]],
        process.calls
      )
      assert_includes(output.string, "RUN  2 test files")
      assert_includes(output.string, "a.test.rb")
      assert_includes(output.string, "z.test.rb")
    end
  end

  def test_ci_runs_once_by_default
    with_context("value.test.rb" => "def test_value; end\n") do |context|
      process = FakeProcess.new
      runner = runner(context: -> { context }, env: {"CI" => "1", "NO_COLOR" => "1"}, process:)

      status = runner.call

      assert_equal(0, status)
      assert_equal(1, process.calls.length)
    end
  end

  def test_run_returns_the_worker_exit_status
    with_context("value.test.rb" => "def test_value; end\n") do |context|
      process = FakeProcess.new(status: 7)
      runner = runner(watch: false, context: -> { context }, process:)

      assert_equal(7, runner.call)
    end
  end

  def test_run_succeeds_without_spawning_when_no_tests_exist
    with_context do |context|
      process = FakeProcess.new
      runner = runner(watch: false, context: -> { context }, process:)

      assert_equal(0, runner.call)
      assert_empty(process.calls)
    end
  end

  def test_run_can_spawn_a_worker_when_no_tests_exist
    with_context do |context|
      process = FakeProcess.new
      runner = runner(watch: false, spawn_empty: true, context: -> { context }, process:)

      assert_equal(0, runner.call)
      assert_equal([[RbConfig.ruby, "/app/test", "--worker", "--"]], process.calls)
    end
  end

  def test_reports_missing_test_plugin
    context = Klenod::Build::Context.new(
      source_dir: Dir.mktmpdir,
      plugins: [Klenod::Build::Plugins::RubyPlugin.new]
    )
    error_output = StringIO.new
    runner = runner(watch: false, context: -> { context }, error_output:)

    assert_equal(1, runner.call)
    assert_includes(error_output.string, "must include Klenod::Test::Plugin")
  end

  def test_worker_reports_errors_with_the_configured_formatter
    error_output = StringIO.new
    runner = runner(
      worker_paths: ["broken.test.rb"],
      context: -> { :context },
      execute: ->(*) { raise "broken" },
      error_output:,
      format_error: ->(error, context) { "#{context}: #{error.message}" }
    )

    assert_equal(1, runner.call)
    assert_equal("context: broken\n", error_output.string)
  end

  def test_watch_reruns_only_tests_related_to_an_update
    with_context(
      "shared.rb" => "VALUE = 1\n",
      "other.rb" => "VALUE = 2\n",
      "shared.test.rb" => "Shared = import(\"./shared\")\n",
      "other.test.rb" => "Other = import(\"./other\")\n"
    ) do |context, directory|
      process = FakeProcess.new
      watcher = fake_watcher
      changed_path = File.join(directory, "shared.rb")
      update = lambda do
        File.write(changed_path, "VALUE = 3\n")
        result = context.invalidate_paths([changed_path])
        context.emit_update(Klenod::Build::UpdateEvent.new([changed_path], [], 1, result))
        raise Interrupt
      end
      runner = runner(
        watch: true,
        context: -> { context },
        process:,
        watcher:,
        wait: update
      )

      assert_equal(0, runner.call)

      assert_equal(
        [
          [RbConfig.ruby, "/app/test", "--worker", "--", "other.test.rb", "shared.test.rb"],
          [RbConfig.ruby, "/app/test", "--worker", "--", "shared.test.rb"]
        ],
        process.calls
      )
      assert(watcher.stopped?)
    end
  end

  def test_gemspec_packages_the_runner_without_a_test_framework_dependency
    spec = Gem::Specification.load(File.expand_path("../../../klenod-test.gemspec", __dir__))

    assert_includes(spec.files, "lib/klenod/test.rb")
    assert_includes(spec.files, "lib/klenod/test/runner.rb")
    assert_includes(spec.files, "lib/klenod/test/config.rb")
    assert_includes(spec.files, "lib/klenod/test/cli.rb")
    assert_includes(spec.files, "lib/klenod/test/plugin.rb")
    assert_includes(spec.files, "lib/klenod/test/suite.rb")
    assert_includes(spec.files, "lib/klenod/test/coverage.rb")
    refute(spec.files.any? { |path| path.end_with?(".test.rb") })
    assert_equal(["async-process", "covered", "klenod-build"], spec.runtime_dependencies.map(&:name).sort)
  end

  private

  def runner(context: -> { raise "unused" }, execute: ->(*) { 0 }, process: FakeProcess.new, **options)
    InspectableRunner.new(
      context:,
      execute:,
      worker_command: [RbConfig.ruby, "/app/test"],
      process:,
      output: StringIO.new,
      error_output: StringIO.new,
      env: {"NO_COLOR" => "1"},
      **options
    )
  end

  def with_context(files = {})
    Dir.mktmpdir do |directory|
      files.each do |path, source|
        full_path = File.join(directory, path)
        FileUtils.mkdir_p(File.dirname(full_path))
        File.write(full_path, source)
      end
      plugin = Klenod::Test::Plugin.new
      context = Klenod::Build::Context.new(
        source_dir: directory,
        plugins: [plugin, Klenod::Build::Plugins::RubyPlugin.new]
      )
      yield context, directory
    end
  end

  def fake_watcher
    watcher = Object.new
    watcher.define_singleton_method(:start) {}
    watcher.define_singleton_method(:stop) { @stopped = true }
    watcher.define_singleton_method(:stopped?) { @stopped }
    watcher
  end
end
