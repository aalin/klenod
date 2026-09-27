# frozen_string_literal: true

require_relative "errors"
require_relative "source_excerpt"

module Klenod
  module Build
    module ResolutionErrorFormatter
      module_function

      def format(error, source_root: nil, source_context: nil, ansi: false)
        return error.message unless error.resolution_failure?

        lines = [SourceExcerpt.header(error.title, "", ansi:), "", "  Import:      #{error.requested_specifier}"]
        lines << "  Imported by: #{error.imported_by}" if error.imported_by
        lines << "  Source root: #{source_root}" if source_root
        append_suggestions(lines, error)
        lines.concat(["", source_context]) if source_context
        lines.join("\n")
      end

      def append_suggestions(lines, error)
        return if error.suggestions.empty?

        lines.concat(["", (error.reason == :incorrect_case) ? "  Use:" : "  Did you mean?"])
        error.suggestions.each { |suggestion| lines << "    - #{suggestion}" }
      end
      private_class_method :append_suggestions
    end
  end
end
