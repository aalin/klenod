# frozen_string_literal: true

require_relative "languages/css"
require_relative "languages/haml"
require_relative "languages/ruby"
require_relative "languages/syntax"

module Klenod
  module LSP
    # Maps a document to the handler that knows its syntax. Handlers respond
    # to `diagnostics(analysis)`, `document_links(analysis, workspace)`,
    # `code_actions(analysis, lines, workspace)`, `document_symbols(analysis)`,
    # `code_lenses(analysis, workspace, index)`, `prepare_rename(analysis,
    # position)`, `rename(analysis, position, new_name, workspace)`, `references(analysis,
    # position, workspace, index, include_declaration:)`, and to `definition`,
    # `hover`, and `completion`, each taking `(analysis, position, workspace)`.
    module Languages
      HANDLERS = {
        ".haml" => Haml.new,
        ".rb" => Ruby.new,
        ".css" => CSS.new
      }.freeze

      module_function

      def for(document)
        return nil unless document.module_id

        HANDLERS[document.extname]
      end

      # The import syntax of a file by extension, Ruby-shaped by default.
      def syntax_for(extname)
        HANDLERS[extname]&.syntax || Syntax::Ruby
      end
    end
  end
end
