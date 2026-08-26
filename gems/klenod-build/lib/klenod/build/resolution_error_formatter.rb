# frozen_string_literal: true

require_relative "errors"

module Klenod
  module Build
    module ResolutionErrorFormatter
      ANSI_BACKGROUND = "\e[0;48;5;52m"

      module_function

      def format(error, source_root: nil, source_context: nil, ansi: false)
        return error.message unless error.resolution_failure?

        lines = [error.title, "", "  Import:      #{error.requested_specifier}"]
        lines << "  Imported by: #{error.imported_by}" if error.imported_by
        lines << "  Source root: #{source_root}" if source_root
        append_suggestions(lines, error)
        lines.concat(["", source_context]) if source_context
        text = lines.join("\n")
        ansi ? format_ansi(text) : text
      end

      def format_ansi(text)
        title, separator, body = text.partition("\n")
        body = body.gsub("\e[0m", ANSI_BACKGROUND)
        body = "\n#{body}" unless separator.empty?

        "\e[1;31;47m ERROR \e[1;37;41m #{title} #{ANSI_BACKGROUND}#{body}\e[0m"
      end
      private_class_method :format_ansi

      def append_suggestions(lines, error)
        return if error.suggestions.empty?

        lines.concat(["", (error.reason == :incorrect_case) ? "  Use:" : "  Did you mean?"])
        error.suggestions.each { |suggestion| lines << "    - #{suggestion}" }
      end
      private_class_method :append_suggestions
    end
  end
end
