# frozen_string_literal: true

require "klenod/build"

require_relative "../server/errors"
require_relative "../web_config"
require_relative "minitest_adapter"

module Example
  module Testing
    module TestRunner
      module_function

      def context
        WebConfig.build_config(mode: :development).context
      end

      def execute(context, test_paths, error_output: $stderr)
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
    end
  end
end
