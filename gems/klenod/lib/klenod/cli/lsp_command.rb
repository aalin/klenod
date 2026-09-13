# frozen_string_literal: true

require "klenod/build/cli"

module Klenod
  module CLI
    # The language server ships in the separate klenod-lsp gem. The `lsp`
    # subcommand stays visible without it so the help output explains what
    # to install.
    class MissingLSPCommand < Samovar::Command
      self.description = "Start a language server for editors (requires the klenod-lsp gem)."

      MESSAGE = "The klenod-lsp gem is not installed. Add `gem \"klenod-lsp\"` to your Gemfile to use `klenod lsp`."

      def call
        output.puts MESSAGE
        1
      end
    end

    def self.lsp_command
      require "klenod/lsp/cli"
      Klenod::LSP::CLI::Command
    rescue LoadError
      MissingLSPCommand
    end
  end
end
