# frozen_string_literal: true

module Klenod
  module Build
    module Plugins
      # Compiles Ruby-style `#{...}` interpolation in filter text into Ruby
      # source. `\#{` stays literal.
      module TextInterpolation
        ESCAPED_SENTINEL = "klenod_escaped_interpolation"

        module_function

        # Replaces escaped interpolation so later parsing, such as Markdown,
        # leaves it alone. Pair with `restore_escapes`.
        def protect_escapes(source)
          source.gsub("\\\#{", ESCAPED_SENTINEL)
        end

        def restore_escapes(text)
          text.gsub(ESCAPED_SENTINEL, "\#{")
        end

        # Returns Ruby source for each literal and interpolated segment of
        # already protected text.
        def expressions(text)
          segments(text).map { |kind, value| (kind == :ruby) ? "(#{value})" : value.inspect }
        end

        # Returns Ruby source for one String built from already protected text.
        def string_source(text)
          parts = segments(text)
          return (parts.first&.last || "").inspect if parts.none? { |kind, _| kind == :ruby }

          body = parts.map { |kind, value| (kind == :ruby) ? "\#{#{value}}" : value.inspect[1...-1] }.join
          "\"#{body}\""
        end

        def segments(text)
          return [[:text, restore_escapes(text)]] unless text.include?("\#{")

          segments = []
          buffer = +""
          index = 0

          while index < text.length
            if text[index, 2] == "\#{"
              expression, next_index = read_interpolation(text, index + 2)
              if expression
                segments << [:text, restore_escapes(buffer)] unless buffer.empty?
                buffer = +""
                segments << [:ruby, expression]
                index = next_index
              else
                buffer << text[index]
                index += 1
              end
            else
              buffer << text[index]
              index += 1
            end
          end

          segments << [:text, restore_escapes(buffer)] unless buffer.empty?
          segments
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
