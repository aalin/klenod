# frozen_string_literal: true

require_relative "languages/haml"
require_relative "languages/ruby"

module Klenod
  module LSP
    # Maps a document to the handler that knows its syntax. Handlers respond
    # to `diagnostics(analysis)`, `document_links(analysis, workspace)`,
    # `code_actions(analysis, lines, workspace)`, `document_symbols(analysis)`, `references(analysis,
    # position, workspace, index, include_declaration:)`, and to `definition`,
    # `hover`, and `completion`, each taking `(analysis, position, workspace)`.
    module Languages
      HANDLERS = {
        ".haml" => Haml.new,
        ".rb" => Ruby.new
      }.freeze

      module_function

      def for(document)
        return nil unless document.module_id

        HANDLERS[document.extname]
      end
    end
  end
end
