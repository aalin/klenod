# frozen_string_literal: true

require "rbconfig"

require "klenod/build/cli"

require_relative "config"
require_relative "coverage"
require_relative "runner"

module Klenod
  module Test
    module CLI
      class Command < Samovar::Command
        self.description = "Run and watch application tests."

        options do
          option "--run", "Run all tests once."
          option "--watch", "Run all tests, then watch for changes."
          option "--worker", "Run selected test files in a worker process."
        end

        split :test_paths, "Test paths passed to the worker."

        def call
          config_path = ConfigLoader.find
          unless config_path
            output.puts "Could not find klenod.test.rb"
            return 1
          end

          config = ConfigLoader.load(config_path)
          Dir.chdir(config.base_dir) do
            Klenod::Test::Runner.new(
              context: config.context,
              execute: config.execute,
              **runner_options,
              worker_command: worker_command,
              output:,
              format_error: config.format_error
            ).call
          end
        rescue ConfigError => error
          output.puts error.message
          1
        end

        private

        def runner_options
          selected = [@options[:run] && false, @options[:watch] && true].compact
          raise ConfigError, "Choose either --run or --watch" if selected.length > 1

          paths = Array(@test_paths)
          if @options[:worker]
            raise ConfigError, "--worker cannot be combined with --run or --watch" unless selected.empty?

            {worker_paths: paths}
          elsif paths.empty?
            selected.empty? ? {} : {watch: selected.first}
          else
            raise ConfigError, "Test paths are only accepted with --worker"
          end
        end

        def worker_command
          [RbConfig.ruby, Gem.bin_path("klenod", "klenod"), "test"]
        end
      end

      class CoverageCommand < Samovar::Command
        self.description = "Run the full application test suite with coverage."

        options do
          option "--report <name>", "Coverage report: brief, partial, full, markdown, or quiet."
          option "--minimum <percent>", "Fail below this overall coverage percentage."
          option "--worker", "Run selected test files in a coverage worker process."
        end

        split :test_paths, "Test paths passed to the worker."

        def call
          config_path = ConfigLoader.find
          unless config_path
            output.puts "Could not find klenod.test.rb"
            return 1
          end

          config = ConfigLoader.load(config_path)
          coverage_config = coverage_config(config.coverage)
          Dir.chdir(config.base_dir) do
            Klenod::Test::Runner.new(
              context: config.context,
              execute: coverage_execute(config, coverage_config),
              watch: false,
              worker_paths: worker_paths,
              spawn_empty: true,
              worker_command: worker_command,
              output:,
              format_error: config.format_error
            ).call
          end
        rescue ConfigError => error
          output.puts error.message
          1
        end

        private

        def coverage_config(config)
          CoverageConfig.build(
            report: @options[:report] || config.report,
            minimum: @options[:minimum] || config.minimum
          )
        end

        def coverage_execute(config, coverage_config)
          lambda do |context, test_paths|
            plugin = context.graph.plugins.find { it.is_a?(Klenod::Test::Plugin) }
            raise ArgumentError, "The Klenod context must include Klenod::Test::Plugin" unless plugin

            CoverageRunner.new(context:, plugin:, config: coverage_config, output:).call do
              config.execute.call(context, test_paths)
            end
          end
        end

        def worker_paths
          paths = Array(@test_paths)
          return paths if @options[:worker]

          raise ConfigError, "Test paths are only accepted with --worker" unless paths.empty?

          nil
        end

        def worker_command
          command = [RbConfig.ruby, Gem.bin_path("klenod", "klenod"), "coverage"]
          command.concat(["--report", @options[:report]]) if @options[:report]
          command.concat(["--minimum", @options[:minimum]]) if @options[:minimum]
          command
        end
      end
    end
  end
end
