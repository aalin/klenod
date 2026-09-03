# frozen_string_literal: true

module Klenod
  module Test
    class ConfigError < ArgumentError; end

    Config = Data.define(:base_dir, :context, :execute, :format_error)

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

      def config
        missing = []
        missing << "context" unless @context
        missing << "execute" unless @execute
        raise ConfigError, "#{@path}: missing #{missing.join(" and ")}" unless missing.empty?

        Config.new(
          base_dir: File.dirname(@path),
          context: @context,
          execute: @execute,
          format_error: @format_error
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
