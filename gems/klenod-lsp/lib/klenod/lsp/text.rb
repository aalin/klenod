# frozen_string_literal: true

require "language_server-protocol"

module Klenod
  module LSP
    # Line and character arithmetic shared by every language handler.
    #
    # Klenod's parsers report lines but not columns, so character ranges are
    # recovered by scanning the original line text. Characters are counted as
    # Ruby characters, which matches LSP's UTF-16 encoding for every character
    # in the Basic Multilingual Plane.
    module Text
      Interface = LanguageServer::Protocol::Interface

      Position = Data.define(:line, :character)

      Span = Data.define(:line, :start_character, :end_character) do
        # Cursor positions directly after the last character count as inside,
        # which is where an editor places the caret at the end of a word.
        def include?(position)
          position.line == line && position.character.between?(start_character, end_character)
        end

        def to_range
          Interface::Range.new(
            start: Interface::Position.new(line: line, character: start_character),
            end: Interface::Position.new(line: line, character: end_character)
          )
        end
      end

      module_function

      def each_match(line_text, line_index, regex, group:)
        offset = 0
        while (match = regex.match(line_text, offset))
          start_character = match.begin(group)
          end_character = match.end(group)
          yield match, Span.new(line_index, start_character, end_character)
          offset = [match.end(0), offset + 1].max
        end
      end

      def line_span(lines, line_index)
        line_index = line_index.clamp(0, [lines.length - 1, 0].max)
        Span.new(line_index, 0, lines[line_index]&.length || 0)
      end

      def zero_range
        Span.new(0, 0, 0).to_range
      end
    end
  end
end
