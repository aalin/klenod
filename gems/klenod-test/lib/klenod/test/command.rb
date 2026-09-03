# frozen_string_literal: true

require "optparse"
require "rbconfig"

require "klenod/build"

module Klenod
  module Test
    class Command
      WORKER_ARGUMENT = "--worker"

      def initialize(
        arguments,
        context:,
        execute:,
        worker_command: [RbConfig.ruby, $PROGRAM_NAME],
        output: $stdout,
        error_output: $stderr,
        env: ENV,
        format_error: nil
      )
        @arguments = arguments.dup
        @context_factory = context
        @execute = execute
        @worker_command = Array(worker_command)
        @output = output
        @error_output = error_output
        @env = env
        @format_error = format_error || ->(error, _context) { error.full_message }
        @last_status = 0
        @worker_mutex = Mutex.new
      end

      def call
        return run_worker(worker_paths) if arguments.first == WORKER_ARGUMENT

        @watch = watch?
        context = context_factory.call
        plugin = test_plugin(context)
        suite = Klenod::Build::TestSuite.new(context:, plugin:)
        selection = suite.collect
        return run_in_worker(selection.test_paths) unless watch

        run_watch(context, suite, selection)
      rescue OptionParser::ParseError, ArgumentError => error
        error_output.puts error.message
        error_output.puts option_parser unless error.is_a?(ArgumentError)
        1
      end

      private

      attr_reader :arguments, :context_factory, :execute, :worker_command, :output,
        :error_output, :env, :format_error, :last_status, :watch

      def run_watch(context, suite, selection)
        watcher = build_watcher(context)
        context.on_update do |event|
          related = suite.update(event)
          log_removed(related.removed_test_paths)
          run_in_worker(related.test_paths) unless related.test_paths.empty?
        end

        begin
          watcher.start
          run_in_worker(selection.test_paths)
          wait_for_changes
        rescue Interrupt
          output.puts
        ensure
          watcher.stop
        end

        last_status
      end

      def run_in_worker(test_paths)
        @worker_mutex.synchronize do
          clear_screen
          report_test_paths(test_paths)
          @last_status = test_paths.empty? ? 0 : worker_status(test_paths)
          report_watch_status if watch
          last_status
        end
      end

      def worker_status(test_paths)
        pid = Process.spawn(*worker_command, WORKER_ARGUMENT, "--", *test_paths)
        _pid, status = Process.wait2(pid)
        status.success? ? 0 : (status.exitstatus || 1)
      end

      def run_worker(test_paths)
        context = context_factory.call
        Integer(execute.call(context, test_paths))
      rescue => error
        error_output.puts format_error.call(error, context)
        1
      end

      def worker_paths
        arguments.shift
        arguments.shift if arguments.first == "--"
        arguments
      end

      def test_plugin(context)
        context.graph.plugins.find do |candidate|
          candidate.is_a?(Klenod::Build::Plugins::TestPlugin::Plugin)
        end || raise(ArgumentError, "The Klenod context must include TestPlugin")
      end

      def watch?
        selected = !env.key?("CI")
        option_parser.parse!(arguments)
        raise OptionParser::InvalidArgument, arguments.join(" ") unless arguments.empty?

        @selected_watch.nil? ? selected : @selected_watch
      end

      def option_parser
        @option_parser ||=
          OptionParser.new do |options|
            options.banner = "Usage: test [--run | --watch]"
            options.on("--run", "Run all tests once") { @selected_watch = false }
            options.on("--watch", "Run all tests, then watch for changes") { @selected_watch = true }
          end
      end

      def build_watcher(context)
        Klenod::Build::Watcher.new(source_dir: context.graph.source_dir, context:)
      end

      def wait_for_changes
        loop { sleep }
      end

      def log_removed(paths)
        paths.each { |path| output.puts "Removed #{path}" }
      end

      def clear_screen
        return unless watch && output.respond_to?(:tty?) && output.tty?

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
end
