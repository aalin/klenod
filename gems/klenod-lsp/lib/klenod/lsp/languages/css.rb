# frozen_string_literal: true

require_relative "../diagnostics"
require_relative "imports"
require_relative "syntax"

module Klenod
  module LSP
    module Languages
      # Stylesheets under the source directory: build diagnostics plus
      # navigation and completion for `@import`, `url()`, and `composes ...
      # from` references, resolved the way the CSS plugin resolves them.
      class CSS
        include ImportNavigation

        Interface = LanguageServer::Protocol::Interface

        def syntax
          Syntax::CSS
        end

        def diagnostics(analysis, _workspace = nil, _index = nil)
          Diagnostics.for_analysis(analysis, syntax: syntax)
        end

        def completion(analysis, position, workspace, _index = nil)
          line_text = analysis.lines[position.line]
          return nil unless line_text

          items = Imports.completion_items(line_text[0...position.character].to_s, position, analysis, workspace, syntax: syntax)
          items && Interface::CompletionList.new(is_incomplete: false, items: items)
        end

        def document_symbols(_analysis)
          []
        end

        def target_at(analysis, position)
          line_text = analysis.lines[position.line]
          line_text && Imports.target_at(line_text, position, syntax: syntax)
        end
      end
    end
  end
end
