# frozen_string_literal: true

module Klenod
  module Test
    class ConfigError < ArgumentError; end

    COVERAGE_REPORTS = %i[brief partial full markdown quiet].freeze

    CoverageConfig = Data.define(:report, :minimum) do
      def self.build(report: :brief, minimum: nil)
        report = report.to_s.downcase.to_sym
        unless COVERAGE_REPORTS.include?(report)
          raise ConfigError, "Unknown coverage report #{report.inspect}; choose one of: #{COVERAGE_REPORTS.join(", ")}"
        end

        new(report, normalize_minimum(minimum))
      end

      def self.normalize_minimum(minimum)
        return unless minimum

        value = begin
          Float(minimum)
        rescue ArgumentError, TypeError
          raise ConfigError, "Coverage minimum must be a number between 0 and 100"
        end
        return value if value.between?(0, 100)

        raise ConfigError, "Coverage minimum must be between 0 and 100"
      end
    end

    Config = Data.define(:base_dir, :context, :execute, :format_error, :coverage)

    class ConfigBuilder
      def initialize(path)
        @path = File.expand_path(path)
      end

      def context(&block)
        @context = block
      end

      def execute(&block)
        @execute = block
      end

      def format_error(&block)
        @format_error = block
      end

      def coverage(report: :brief, minimum: nil)
        @coverage = CoverageConfig.build(report:, minimum:)
      end

      def config
        missing = []
        missing << "context" unless @context
        missing << "execute" unless @execute
        raise ConfigError, "#{@path}: missing #{missing.join(" and ")}" unless missing.empty?

        Config.new(
          base_dir: File.dirname(@path),
          context: @context,
          execute: @execute,
          format_error: @format_error,
          coverage: @coverage || CoverageConfig.build
        )
      end
    end

    module ConfigLoader
      CONFIG_FILE = "klenod.test.rb"

      module_function

      def find(start_dir = Dir.pwd)
        dir = File.expand_path(start_dir)

        loop do
          path = File.join(dir, CONFIG_FILE)
          return path if File.file?(path)

          parent = File.dirname(dir)
          return nil if parent == dir

          dir = parent
        end
      end

      def load(path)
        builder = ConfigBuilder.new(path)
        builder.instance_eval(File.read(path), path, 1)
        builder.config
      end
    end
  end
end
