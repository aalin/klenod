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
        option "--config <path>", "Ruby config file.", default: "klenod.rb"
        option "--source <path>", "Source directory."
        option "--entry <specifier>", "Entrypoint specifier."
        option "--output <path>", "Bundle output path.", key: :bundle_output
        option "--assets-dir <path>", "Directory for emitted asset files."
      end

      def call
        config = build_config
        entrypoints = config.entrypoints
        raise Samovar::MissingValueError.new(self, :entry) if entrypoints.empty?

        source_dir = expand_config_path(config.source_dir, config)
        output = expand_config_path(config.output, config)
        assets_dir = config.assets_dir && expand_config_path(config.assets_dir, config)

        context = Klenod::Build::Context.new(source_dir: source_dir, plugins: config.plugins, mode: config.mode)
        bundle = context.build(entrypoints: entrypoints, output: output, assets_dir: assets_dir)

        self.output.puts "Built #{output}"
        self.output.puts "Source root: #{bundle.source_root}"
        self.output.puts "Entrypoints: #{bundle.entrypoints.keys.join(", ")}"
        self.output.puts "Assets: #{bundle.assets.length}"
        self.output.puts "Assets directory: #{assets_dir}" if assets_dir

        bundle
      end

      private

      def build_config
        config = load_config
        config = config.with(source_dir: @options[:source]) if @options.key?(:source)
        config = config.with(entrypoints: [@options[:entry]]) if @options[:entry]
        config = config.with(output: @options[:bundle_output]) if @options[:bundle_output]
        config = config.with(assets_dir: @options[:assets_dir]) if @options[:assets_dir]
        config
      end

      def load_config
        path = @options.fetch(:config)
        return Klenod::Build::Config.new unless File.exist?(path)

        Klenod::Build::ConfigLoader.load(path)
      end

      def expand_config_path(path, config)
        path = path.to_s
        return File.expand_path(path) if Pathname.new(path).absolute?

        File.expand_path(path, config.base_dir)
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
