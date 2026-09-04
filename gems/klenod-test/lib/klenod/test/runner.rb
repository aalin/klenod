# frozen_string_literal: true

require "rbconfig"

require "async/process"
require "klenod/build"

require_relative "plugin"
require_relative "suite"

module Klenod
  module Test
    class Runner
      WORKER_ARGUMENT = "--worker"

      def self.worker_paths_from(arguments)
        arguments = Array(arguments)
        return unless arguments.first == WORKER_ARGUMENT
        raise ArgumentError, "Expected -- after #{WORKER_ARGUMENT}" unless arguments[1] == "--"

        arguments.drop(2)
      end

      def initialize(
        context:,
        execute:,
        watch: nil,
        worker_paths: Runner.worker_paths_from(ARGV),
        spawn_empty: false,
        worker_command: [RbConfig.ruby, $PROGRAM_NAME],
        process: Async::Process,
        output: $stdout,
        error_output: $stderr,
        env: ENV,
        format_error: nil
      )
        @context_factory = context
        @execute = execute
        @watch = watch.nil? ? !env.key?("CI") : watch
        @worker_paths = worker_paths&.dup
        @spawn_empty = spawn_empty
        @worker_command = Array(worker_command)
        @process = process
        @output = output
        @error_output = error_output
        @env = env
        @format_error = format_error || ->(error, _context) { error.full_message }
        @last_status = 0
        @worker_mutex = Mutex.new
      end

      def call
        return run_worker(worker_paths) if worker_paths

        context = context_factory.call
        plugin = test_plugin(context)
        suite = Klenod::Test::Suite.new(context:, plugin:)
        selection = suite.collect
        return run_in_worker(selection.test_paths) unless watch

        run_watch(context, suite, selection)
      rescue ArgumentError => error
        error_output.puts error.message
        1
      end

      private

      attr_reader :context_factory, :execute, :watch, :worker_paths, :worker_command,
        :spawn_empty, :process, :output, :error_output, :env, :format_error, :last_status

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
          @last_status = (test_paths.empty? && !spawn_empty) ? 0 : worker_status(test_paths)
          report_watch_status if watch
          last_status
        end
      end

      def worker_status(test_paths)
        status = process.spawn(*worker_command, WORKER_ARGUMENT, "--", *test_paths)
        status.success? ? 0 : (status.exitstatus || 1)
      end

      def run_worker(test_paths)
        context = context_factory.call
        Integer(execute.call(context, test_paths))
      rescue => error
        error_output.puts format_error.call(error, context)
        1
      end

      def test_plugin(context)
        context.graph.plugins.find do |candidate|
          candidate.is_a?(Klenod::Test::Plugin)
        end || raise(ArgumentError, "The Klenod context must include Klenod::Test::Plugin")
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
        return value unless output.respond_to?(:tty?) && output.tty?

        codes = {run: "\e[1;34m", success: "\e[1;32m", failure: "\e[1;31m"}
        "#{codes.fetch(name)}#{value}\e[0m"
      end
    end
  end
end
