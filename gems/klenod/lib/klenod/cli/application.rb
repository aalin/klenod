# frozen_string_literal: true

require "klenod/build/cli"
require "klenod/test/cli"
require_relative "lsp_command"

module Klenod
  module CLI
    class Application < Samovar::Command
      self.description = "Build, test, and develop Klenod applications."

      options do
        option "-h/--help", "Print this help."
        option "-v/--version", "Print the Klenod version."
      end

      nested :command, {
        "build" => Klenod::Build::CLI::Build,
        "coverage" => Klenod::Test::CLI::CoverageCommand,
        "graph" => Klenod::Build::CLI::Graph,
        "lsp" => Klenod::CLI.lsp_command,
        "test" => Klenod::Test::CLI::Command
      }

      def call
        if @options[:version]
          output.puts Klenod::Build::VERSION
        elsif @options[:help] || !@command
          print_usage
        else
          @command.call
        end
      end
    end
  end
end
