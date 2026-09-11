# frozen_string_literal: true

module Klenod
  module Build
    # Shared formatting for parse errors that can point at a line of source.
    #
    # Plugins raise errors carrying the original source and a line number, and
    # the resulting message is shown both in the terminal and in the browser
    # error dialog, so it needs to read well as plain text.
    module SourceExcerpt
      module_function

      # "app:/pages/thing.tsx:33: JavaScript parse error"
      def title(module_id:, line:, kind:)
        location =
          if module_id && line
            "#{module_id}:#{line}"
          elsif module_id
            module_id.to_s
          elsif line
            "line #{line}"
          end

        location ? "#{location}: #{kind}" : kind
      end

      def message(module_id:, line:, kind:, source:, message:, context: 2)
        [
          title(module_id:, line:, kind:),
          message,
          excerpt(source:, line:, context:)
        ].compact.join("\n\n")
      end

      def excerpt(source:, line:, context: 2)
        return nil unless line

        lines = source.to_s.lines
        return nil if lines.empty?

        index = line - 1
        return nil unless index.between?(0, lines.length - 1)

        first = [index - context, 0].max
        last = [index + context, lines.length - 1].min
        width = (last + 1).to_s.length
        excerpt =
          (first..last).map do |line_index|
            marker = (line_index == index) ? ">" : " "
            number = (line_index + 1).to_s.rjust(width)
            formatted = "#{marker} #{number} | #{lines.fetch(line_index).chomp}"
            if marker == ">"
              "\e[1;31m#{formatted}\e[0m"
            else
              formatted
            end
          end

        "Source:\n#{excerpt.join("\n")}"
      end
    end
  end
end
