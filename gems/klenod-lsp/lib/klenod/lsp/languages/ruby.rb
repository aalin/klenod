# frozen_string_literal: true

require_relative "../diagnostics"
require_relative "imports"

module Klenod
  module LSP
    module Languages
      # Ruby modules under the source directory: build diagnostics plus
      # navigation and completion for their `import("...")` literals. General
      # Ruby language features are left to a Ruby language server.
      class Ruby
        include ImportNavigation

        Interface = LanguageServer::Protocol::Interface

        def diagnostics(analysis)
          Diagnostics.for_analysis(analysis)
        end

        def completion(analysis, position, workspace)
          line_text = analysis.lines[position.line]
          return nil unless line_text

          items = Imports.completion_items(line_text[0...position.character].to_s, position, analysis, workspace)
          items && Interface::CompletionList.new(is_incomplete: false, items: items)
        end

        def target_at(analysis, position)
          line_text = analysis.lines[position.line]
          line_text && Imports.target_at(line_text, position)
        end
      end
    end
  end
end
