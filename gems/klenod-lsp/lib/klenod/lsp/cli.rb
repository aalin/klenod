# frozen_string_literal: true

require "klenod/build/cli"

require_relative "../lsp"

module Klenod
  module LSP
    module CLI
      # Loads the nearest klenod.config.rb and yields it from its base
      # directory. Returns 1 when there is no config.
      def self.with_config(output)
        config_path = Klenod::Build::ConfigLoader.find
        unless config_path
          output.puts "Could not find klenod.config.rb"
          return 1
        end

        config = nil
        Dir.chdir(File.dirname(config_path)) do
          config = Klenod::Build::ConfigLoader.load(config_path)
        end

        Dir.chdir(config.base_dir) { yield config }
      end

      class Command < Samovar::Command
        self.description = "Start a language server for editors."

        def call
          CLI.with_config(output) do |config|
            context = config.context(mode: :development, analysis: true)
            Klenod::LSP::Server.new(context: context, entrypoints: config.entrypoints).start
          end
        end
      end

      class CheckCommand < Samovar::Command
        self.description = "Report language server diagnostics for every source file."

        many :paths, "Files or directories to check. Defaults to the whole source directory."

        def call
          root = Dir.pwd
          paths = Array(@paths)
          missing = paths.reject { |path| File.exist?(path) }
          unless missing.empty?
            missing.each { |path| output.puts "No such file or directory: #{path}" }
            return 1
          end
          # The source directory is a real path, so selections must be too.
          paths = paths.map { |path| File.realpath(path) }

          CLI.with_config(output) do |config|
            context = config.context(mode: :development, analysis: true)
            results = Klenod::LSP::Check.new(context: context, entrypoints: config.entrypoints).call(paths)
            Klenod::LSP::Check.report(results, output: output, root: root).zero? ? 0 : 1
          end
        end
      end
    end
  end
end
