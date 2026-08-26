# frozen_string_literal: true

require_relative "errors"

module Klenod
  module Build
    module ResolutionErrorFormatter
      module_function

      def format(error)
        return error.message unless error.resolution_failure?

        lines = [error.title, "", "  Import:      #{error.requested_specifier}"]
        lines << "  Imported by: #{error.imported_by}" if error.imported_by
        append_suggestions(lines, error)
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
