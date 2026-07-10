# frozen_string_literal: true

begin
  previous_verbose = $VERBOSE
  $VERBOSE = nil
  require "samovar"
ensure
  $VERBOSE = previous_verbose
end

require_relative "../build/context"
require_relative "../version"

module Klenod
  module CLI
    class Build < Samovar::Command
      self.description = "Build a Klenod runtime bundle."

      def call
        config_path = Klenod::Build::ConfigLoader.find
        raise Samovar::InvalidInputError.new(self, ["Could not find klenod.config.rb"]) unless config_path

        config = nil
        Dir.chdir(File.dirname(config_path)) do
          config = Klenod::Build::ConfigLoader.load(config_path)
        end
        entrypoints = config.entrypoints
        raise Samovar::MissingValueError.new(self, :entry) if entrypoints.empty?

        output = config.output_path
        assets_dir = config.assets_path

        bundle = nil
        Dir.chdir(config.base_dir) do
          context = config.context
          bundle = context.build(entrypoints: entrypoints, output: output, assets_dir: assets_dir)
        end

        self.output.puts "Built #{output}"
        self.output.puts "Source root: #{bundle.source_root}"
        self.output.puts "Entrypoints: #{bundle.entrypoints.keys.join(", ")}"
        self.output.puts "Assets: #{bundle.assets.length}"
        self.output.puts "Assets directory: #{assets_dir}" if assets_dir

        bundle
      end
    end

    class Application < Samovar::Command
      self.description = "Build and develop Klenod applications."

      options do
        option "-h/--help", "Print this help."
        option "-v/--version", "Print the Klenod version."
      end

      nested :command, {
        "build" => Build
      }

      def call
        if @options[:version]
          output.puts Klenod::VERSION
        elsif @options[:help] || !@command
          print_usage
        else
          @command.call
        end
      end
    end
  end
end
