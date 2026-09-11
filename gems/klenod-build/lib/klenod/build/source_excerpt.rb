# frozen_string_literal: true

module Klenod
  module Build
    # Shared formatting for build errors that can point at a line of source.
    #
    # Plugins raise errors carrying the original source and a location, and the
    # resulting message is shown both in the terminal and in the browser error
    # dialog, so it needs to read well as plain text. The browser passes
    # `ansi: false` to get the same layout without escape codes.
    module SourceExcerpt
      MARKED_LINE = "\e[1;31m"
      RESET = "\e[0m"

      module_function

      # "app:/pages/thing.tsx:33:9: JavaScript parse error"
      def title(module_id:, line:, kind:, column: nil)
        location =
          if module_id && line
            "#{module_id}:#{[line, column].compact.join(":")}"
          elsif module_id
            module_id.to_s
          elsif line
            column ? "line #{line} column #{column}" : "line #{line}"
          end

        location ? "#{location}: #{kind}" : kind
      end

      def message(module_id:, line:, kind:, source:, message:, column: nil, hints: [], context: 2, ansi: true)
        [
          title(module_id:, line:, column:, kind:),
          message,
          excerpt(source:, line:, column:, context:, ansi:),
          hint_section(hints)
        ].compact.join("\n\n")
      end

      def excerpt(source:, line:, column: nil, context: 2, ansi: true)
        return nil unless line

        lines = source.to_s.lines
        return nil if lines.empty?

        index = line - 1
        return nil unless index.between?(0, lines.length - 1)

        first = [index - context, 0].max
        last = [index + context, lines.length - 1].min
        width = (last + 1).to_s.length

        rows =
          (first..last).flat_map do |line_index|
            marked = line_index == index
            number = (line_index + 1).to_s.rjust(width)
            formatted = "#{marked ? ">" : " "} #{number} | #{lines.fetch(line_index).chomp}"
            formatted = "#{MARKED_LINE}#{formatted}#{RESET}" if marked && ansi

            marked ? [formatted, caret_row(width, column)].compact : [formatted]
          end

        "Source:\n#{rows.join("\n")}"
      end

      # "    |       ^", aligned under the offending column of the marked line.
      def caret_row(width, column)
        return nil unless column&.positive?

        "#{" " * (width + 3)}| #{" " * (column - 1)}^"
      end

      # What to try next. Rendered like the "Source:" section so the two read as
      # one report.
      def hint_section(hints)
        hints = Array(hints).map(&:to_s).reject(&:empty?)
        return nil if hints.empty?

        heading = (hints.length == 1) ? "Hint:" : "Hints:"
        "#{heading}\n#{hints.map { "  #{it}" }.join("\n")}"
      end
    end
  end
end
