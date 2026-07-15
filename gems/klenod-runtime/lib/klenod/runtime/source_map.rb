# frozen_string_literal: true

module Klenod
  module Runtime
    module SourceMap
      MARK_PREFIX = "SourceMapMark:"

      Mark = Data.define(:line, :source) do
        def self.parse(value)
          return value if value.is_a?(self)
          return nil unless value

          if value =~ /\ASourceMapMark:(?<line>\d+):(?<encoded>[A-Za-z0-9+\/=]+)\z/
            new($~[:line].to_i, $~[:encoded].unpack1("m0"))
          end
        end

        def to_s
          "#{MARK_PREFIX}#{line}:#{[source].pack("m0")}"
        end
      end

      SourceMap = Data.define(:input, :output, :marks_by_output_line) do
        def self.parse(input, output)
          marks = {}

          output.each_line.with_index(1) do |line, line_no|
            if (mark = Mark.parse(line[/#{MARK_PREFIX}\d+:[A-Za-z0-9+\/=]+/]))
              marks[line_no] = mark
            end
          end

          new(input, output, marks.freeze)
        end

        def find_original_line_no(output_line_no)
          # Marks apply until the next mark, so generated code only needs a mark
          # before the expression it came from.
          marks_by_output_line
            .select { |line_no, _mark| line_no <= output_line_no }
            .max_by { |line_no, _mark| line_no }
            &.last
            &.line
        end
      end
    end
  end
end
