# frozen_string_literal: true

require "rbconfig"

require "klenod/build"
require "klenod/test"

require_relative "../server/errors"
require_relative "../web_config"
require_relative "minitest_adapter"

module Example
  module Testing
    class TestCommand
      def initialize(arguments, output: $stdout, error_output: $stderr, env: ENV)
        @arguments = arguments.dup
        @output = output
        @error_output = error_output
        @env = env
      end

      def call
        env["KLENOD_EXAMPLE_FAKE_GOOGLE_FONTS"] ||= "1"
        Klenod::Test::Command.new(
          arguments,
          context: -> { test_config.context },
          execute: method(:run_tests),
          worker_command: [RbConfig.ruby, executable],
          output:,
          error_output:,
          env:,
          format_error: method(:format_error)
        ).call
      end

      private

      attr_reader :arguments, :output, :error_output, :env

      def test_config
        WebConfig.build_config(mode: :development)
      end

      def run_tests(context, test_paths)
        adapter = MinitestAdapter.new
        loaded = true

        test_paths.each do |path|
          exports = context.entry(path).exports
          adapter.register(path, exports)
        rescue => error
          error_output.puts Server::ServerErrors.format_exception(error, context)
          loaded = false
        end

        (loaded && adapter.run) ? 0 : 1
      end

      def format_error(error, context)
        Server::ServerErrors.format_exception(error, context)
      end

      def executable
        File.expand_path("../../bin/test", __dir__)
      end
    end
  end
end
