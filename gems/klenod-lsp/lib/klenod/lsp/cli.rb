# frozen_string_literal: true

require "klenod/build/cli"

require_relative "../lsp"

module Klenod
  module LSP
    module CLI
      class Command < Samovar::Command
        self.description = "Start a language server for editors."

        def call
          config_path = Klenod::Build::ConfigLoader.find
          unless config_path
            output.puts "Could not find klenod.config.rb"
            return 1
          end

          config = nil
          Dir.chdir(File.dirname(config_path)) do
            config = Klenod::Build::ConfigLoader.load(config_path)
          end

          Dir.chdir(config.base_dir) do
            context = config.context(mode: :development, analysis: true)
            Klenod::LSP::Server.new(context: context, entrypoints: config.entrypoints).start
          end
        end
      end
    end
  end
end
