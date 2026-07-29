# frozen_string_literal: true

require_relative "map"

module Klenod
  module Build
    module SourceMap
      Edit = Data.define(:start_offset, :end_offset, :replacement) do
        def self.replace(start_offset, end_offset, replacement)
          new(start_offset, end_offset, replacement)
        end

        def self.delete(start_offset, end_offset)
          new(start_offset, end_offset, "")
        end
      end

      EditResult = Data.define(:code, :source_map)

      class Editor
        def initialize(code, source_map)
          @code = code
          @source_map = source_map
          @line_starts = line_starts(code)
        end

        def apply(edits)
          edits = edits.sort_by(&:start_offset)
          validate_edits!(edits)
          code = apply_code_edits(edits)
          final_line_starts = line_starts(code)

          segments =
            @source_map.segments.filter_map do |segment|
              offset = offset_for(segment.generated_line, segment.generated_column)
              translated_offset = translate_offset(offset, edits)
              next unless translated_offset

              line, column = line_column_for(translated_offset, final_line_starts)
              segment.with_generated(line, column)
            end

          EditResult.new(code, @source_map.with(segments: segments))
        end

        private

        def validate_edits!(edits)
          edits.each_cons(2) do |current, successor|
            next if current.end_offset <= successor.start_offset

            raise ArgumentError, "Source map edits must not overlap"
          end
        end

        def apply_code_edits(edits)
          result = +""
          offset = 0

          edits.each do |edit|
            result << @code[offset...edit.start_offset]
            result << edit.replacement
            offset = edit.end_offset
          end

          result << @code[offset..]
          result
        end

        def translate_offset(offset, edits)
          delta = 0

          edits.each do |edit|
            return offset + delta if offset < edit.start_offset

            if offset < edit.end_offset
              return nil if edit.replacement.empty?
              return edit.start_offset + delta if offset == edit.start_offset

              return nil
            end

            delta += edit.replacement.length - (edit.end_offset - edit.start_offset)
          end

          offset + delta
        end

        def offset_for(line, column)
          @line_starts.fetch(line) + column
        end

        def line_starts(code)
          starts = [0]
          code.each_char.with_index do |char, index|
            starts << index + 1 if char == "\n"
          end
          starts
        end

        def line_column_for(offset, line_starts)
          index = line_starts.bsearch_index { |line_start| line_start > offset }
          line = index ? index - 1 : line_starts.length - 1

          [line, offset - line_starts.fetch(line)]
        end
      end
    end
  end
end
