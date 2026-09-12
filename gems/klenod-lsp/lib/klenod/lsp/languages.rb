# frozen_string_literal: true

require_relative "languages/haml"

module Klenod
  module LSP
    # Maps a document to the handler that knows its syntax. Handlers respond
    # to `diagnostics(analysis)` and to `definition`, `hover`, and
    # `completion`, each taking `(analysis, position, workspace)`.
    module Languages
      HANDLERS = {
        ".haml" => Haml.new
      }.freeze

      module_function

      def for(document)
        return nil unless document.module_id

        HANDLERS[document.extname]
      end
    end
  end
end
