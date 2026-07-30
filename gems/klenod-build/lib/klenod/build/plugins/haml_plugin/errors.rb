# frozen_string_literal: true

require "klenod/runtime/source_map"

module Klenod
  module Build
    module Plugins
      module HamlPlugin
        class ParseError < StandardError
          attr_reader :module_id, :source, :line, :column, :cause

          def initialize(error, source:, module_id:)
            @cause = error
            @module_id = module_id
            @source = source
            @line = source_line_for(error)
            @column = nil

            super(message_for(error))
            set_backtrace(error.backtrace)
          end

          private

          def source_line_for(error)
            line = error.line if error.respond_to?(:line)
            line ||= full_message_line_for(error)
            return nil unless line.is_a?(Integer)

            # Haml reports zero-based line indexes.
            error_line_zero_based?(error) ? line + 1 : line
          end

          def full_message_line_for(error)
            return nil unless error.respond_to?(:full_message)

            error.full_message(highlight: false, order: :top).match(/\A\(haml\):(?<line>\d+):/) { it[:line].to_i }
          end

          def error_line_zero_based?(error)
            error.respond_to?(:line) && error.line.is_a?(Integer) && !error.is_a?(RubyParseError)
          end

          def message_for(error)
            location =
              if module_id && line
                "#{module_id}:#{line}"
              elsif module_id
                module_id.to_s
              elsif line
                "line #{line}"
              end

            title = location ? "#{location}: Haml parse error" : "Haml parse error"

            [
              title,
              error.message,
              source_excerpt
            ].compact.join("\n\n")
          end

          def source_excerpt
            return nil unless line

            lines = source.lines
            return nil if lines.empty?

            index = line - 1
            first = [index - 2, 0].max
            last = [index + 2, lines.length - 1].min
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

        class RubyParseError < StandardError
          attr_reader :line

          def initialize(message, line: nil)
            @line = line

            super(message)
          end
        end

        HamlTransformResult = ::Data.define(:code, :source_map, :metadata, :ast) do
          def self.from_ast(ast, source:, metadata:)
            code = ast.source

            new(
              code,
              Runtime::SourceMap::SourceMap.parse(source, code),
              metadata,
              ast
            )
          end
        end
      end
    end
  end
end
