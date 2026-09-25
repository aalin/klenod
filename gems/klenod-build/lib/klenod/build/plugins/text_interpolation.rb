# frozen_string_literal: true

module Klenod
  module Build
    module Plugins
      # Compiles Ruby-style `#{...}` interpolation in filter text into Ruby
      # source. `\#{` stays literal.
      #
      # Each interpolation is replaced by an opaque private-use token before
      # the text is parsed further, so parsers such as Markdown never see the
      # Ruby expression. Compile the parsed pieces back with the same Source.
      module TextInterpolation
        TOKEN_START = ""
        TOKEN_END = ""
        ESCAPE_TOKEN = ""
        FIRST_INDEX_CODEPOINT = 0xE100
        LAST_INDEX_CODEPOINT = 0xF8FF
        TOKEN_PATTERN = /#{TOKEN_START}([\u{E100}-\u{F8FF}])#{TOKEN_END}/o
        SEGMENT_PATTERN = /#{TOKEN_START}[\u{E100}-\u{F8FF}]#{TOKEN_END}|#{ESCAPE_TOKEN}/o

        class Source
          # The source with interpolations and escapes replaced by tokens.
          attr_reader :text

          def initialize(source)
            @interpolations = []
            @text = tokenize(source)
          end

          def interpolated?(text = @text)
            text.match?(TOKEN_PATTERN)
          end

          # Returns Ruby source for each literal and interpolated segment of
          # tokenized text.
          def expressions(text)
            segments(text).map { |kind, value| (kind == :ruby) ? "(#{value})" : value.inspect }
          end

          # Returns Ruby source for one String built from tokenized text.
          def string_source(text)
            parts = segments(text)
            return literal(text).inspect if parts.none? { |kind, _| kind == :ruby }

            body = parts.map { |kind, value| (kind == :ruby) ? "\#{#{value}}" : value.inspect[1...-1] }.join
            "\"#{body}\""
          end

          # Restores tokenized text to its original characters, keeping
          # interpolations as literal `#{...}` text.
          def literal(text)
            text.gsub(SEGMENT_PATTERN) do |token|
              (token == ESCAPE_TOKEN) ? "\#{" : @interpolations.fetch(token_index(token)).fetch(:raw)
            end
          end

          private

          def segments(text)
            segments = []
            buffer = +""

            text.split(/(#{SEGMENT_PATTERN})/o).each do |part|
              if part == ESCAPE_TOKEN
                buffer << "\#{"
              elsif part.match?(TOKEN_PATTERN)
                segments << [:text, buffer] unless buffer.empty?
                buffer = +""
                segments << [:ruby, @interpolations.fetch(token_index(part)).fetch(:expression)]
              else
                buffer << part
              end
            end

            segments << [:text, buffer] unless buffer.empty?
            segments
          end

          def token_index(token)
            token[TOKEN_PATTERN, 1].ord - FIRST_INDEX_CODEPOINT
          end

          def tokenize(source)
            output = +""
            index = 0

            while index < source.length
              if source[index, 3] == "\\\#{"
                output << ESCAPE_TOKEN
                index += 3
              elsif source[index, 2] == "\#{" && (interpolation = read_interpolation(source, index + 2))
                expression, next_index = interpolation
                output << token(expression, raw: source[index...next_index])
                index = next_index
              else
                output << source[index]
                index += 1
              end
            end

            output
          end

          def token(expression, raw:)
            codepoint = FIRST_INDEX_CODEPOINT + @interpolations.length
            raise ArgumentError, "Too many interpolations in one filter" if codepoint > LAST_INDEX_CODEPOINT

            @interpolations << {expression: expression, raw: raw}
            "#{TOKEN_START}#{codepoint.chr(Encoding::UTF_8)}#{TOKEN_END}"
          end

          def read_interpolation(text, index)
            expression = +""
            depth = 1
            quote = nil
            escaped = false

            while index < text.length
              char = text[index]

              if quote
                expression << char
                if escaped
                  escaped = false
                elsif char == "\\"
                  escaped = true
                elsif char == quote
                  quote = nil
                end
              else
                case char
                when "\"", "'", "`"
                  quote = char
                when "{"
                  depth += 1
                when "}"
                  depth -= 1
                  return [expression.strip, index + 1] if depth.zero?
                end

                expression << char
              end

              index += 1
            end

            nil
          end
        end
      end
    end
  end
end
