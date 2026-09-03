# frozen_string_literal: true

require "optparse"
require "rbconfig"

require "klenod/build"

require_relative "../server/errors"
require_relative "../web_config"
require_relative "minitest_adapter"

module Example
  class TestCommand
    def initialize(arguments, output: $stdout, error_output: $stderr, env: ENV)
      @arguments = arguments.dup
      @output = output
      @error_output = error_output
      @env = env
      @last_status = 0
      @worker_mutex = Mutex.new
    end

    def call
      return run_worker(worker_paths) if arguments.first == "--worker"

      watch = watch?
      @watch = watch
      config = test_config
      context = config.context
      plugin = context.graph.plugins.find { |candidate| candidate.is_a?(Klenod::Build::Plugins::TestPlugin::Plugin) }
      suite = Klenod::Build::TestSuite.new(context: context, plugin: plugin)
      selection = suite.collect
      unless watch
        run_in_worker(selection.test_paths)
        return last_status
      end

      watcher = Klenod::Build::Watcher.new(source_dir: config.source_path, context: context)
      context.on_update do |event|
        selection = suite.update(event)
        log_removed(selection.removed_test_paths)
        run_in_worker(selection.test_paths) unless selection.test_paths.empty?
      end

      begin
        watcher.start
        run_in_worker(selection.test_paths)
        loop { sleep }
      rescue Interrupt
        output.puts
      ensure
        watcher.stop
      end

      last_status
    end

    private

    attr_reader :arguments, :output, :error_output, :env, :last_status

    def watch?
      watch = !env.key?("CI")
      parser = OptionParser.new do |options|
        options.banner = "Usage: bin/test [--run | --watch]"
        options.on("--run", "Run all tests once") { watch = false }
        options.on("--watch", "Run all tests, then watch for changes") { watch = true }
      end
      parser.parse!(arguments)
      raise OptionParser::InvalidArgument, arguments.join(" ") unless arguments.empty?

      watch
    rescue OptionParser::ParseError => error
      error_output.puts error.message
      error_output.puts parser
      exit 1
    end

    def test_config
      env["KLENOD_EXAMPLE_FAKE_GOOGLE_FONTS"] ||= "1"
      WebConfig.build_config(mode: :development)
    end

    def run_in_worker(test_paths)
      @worker_mutex.synchronize do
        clear_screen
        report_test_paths(test_paths)
        pid = Process.spawn(RbConfig.ruby, executable, "--worker", "--", *test_paths)
        _pid, status = Process.wait2(pid)
        @last_status = status.success? ? 0 : (status.exitstatus || 1)
        report_watch_status if @watch
      end
    end

    def run_worker(test_paths)
      context = test_config.context
      adapter = MinitestAdapter.new
      loaded = true

      test_paths.each do |path|
        exports = context.entry(path).exports
        adapter.register(path, exports)
      rescue => error
        error_output.puts ServerErrors.format_exception(error, context)
        loaded = false
      end

      (loaded && adapter.run) ? 0 : 1
    end

    def worker_paths
      arguments.shift
      arguments.shift if arguments.first == "--"
      arguments
    end

    def executable
      File.expand_path("../../bin/test", __dir__)
    end

    def log_removed(paths)
      paths.each { |path| output.puts "Removed #{path}" }
    end

    def clear_screen
      return unless @watch && output.respond_to?(:tty?) && output.tty?

      output.print "\e[2J\e[H"
    end

    def report_test_paths(test_paths)
      count = test_paths.length
      output.puts "#{color(:run, " RUN ")} #{count} test #{(count == 1) ? "file" : "files"}"
      output.puts
      test_paths.each { |path| output.puts "  #{path}" }
      output.puts
      output.flush
    end

    def report_watch_status
      status = last_status.zero? ? :success : :failure
      label = last_status.zero? ? " PASS " : " FAIL "
      output.puts
      output.puts "#{color(status, label)} Watching for file changes..."
      output.flush
    end

    def color(name, value)
      return value if env.key?("NO_COLOR")

      codes = {run: "\e[1;34m", success: "\e[1;32m", failure: "\e[1;31m"}
      "#{codes.fetch(name)}#{value}\e[0m"
    end
  end
end
