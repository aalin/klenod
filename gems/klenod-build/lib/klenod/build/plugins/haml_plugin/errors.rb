# frozen_string_literal: true

require "klenod/runtime/source_map"
require_relative "../../source_error"

module Klenod
  module Build
    module Plugins
      module HamlPlugin
        class ParseError < Klenod::Build::SourceError
          def kind
            "Haml parse error"
          end

          private

          def location(error)
            detail, *sections = error.message.split(/\n\n+/)

            Location.new(line: source_line_for(error), detail: detail.to_s, hints: hints_from(sections))
          end

          # A RubyParseError explains itself in trailing "Errors:"/"Missing:"
          # sections, each an indented list of what to fix.
          def hints_from(sections)
            sections.flat_map do |section|
              _heading, *lines = section.lines.map(&:chomp)
              lines.map(&:strip)
            end
          end

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
        end

        class RubyParseError < StandardError
          attr_reader :line

          def initialize(message, line: nil)
            @line = line

            super(message)
          end
        end

        HamlTransformResult = Data.define(:code, :source_map, :metadata, :ast) do
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
