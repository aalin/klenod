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

      options do
        option "--source <path>", "Source directory.", default: Dir.pwd
        option "--entry <specifier>", "Entrypoint specifier.", required: true
        option "--output <path>", "Bundle output path.", key: :bundle_output, required: true
        option "--assets-dir <path>", "Directory for emitted asset files."
      end

      def call
        source_dir = File.expand_path(@options.fetch(:source))
        output = File.expand_path(@options.fetch(:bundle_output))
        assets_dir = @options[:assets_dir] && File.expand_path(@options[:assets_dir])

        context = Klenod::Build::Context.new(source_dir: source_dir, mode: :build)
        bundle = context.build(entrypoints: [@options.fetch(:entry)], output: output, assets_dir: assets_dir)

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
