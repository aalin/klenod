# frozen_string_literal: true

require_relative "../../text"
require_relative "../imports"
require_relative "ruby_regions"

module Klenod
  module LSP
    module Languages
      class Haml
        # Where a bound constant appears in a Haml document: the `%Name` tags
        # and the whole-word uses inside Ruby, meaning `:ruby` filters, script
        # lines, tag attributes, and printed tag content. Plain text keeps
        # its words.
        module Rename
          module_function

          def spans(source, name)
            lines = source.lines(chomp: true)
            spans = []

            RubyRegions.each(source, lines) do |line_index, start_character, text|
              Imports.constant_spans(text, line_index, name).each do |span|
                spans << span.with(start_character: span.start_character + start_character, end_character: span.end_character + start_character)
              end
            end

            lines.each_with_index do |line_text, index|
              Text.each_match(line_text, index, Haml::COMPONENT_TAG, group: :name) do |match, span|
                next unless match[:name].split("::").first == name

                spans << Text::Span.new(index, span.start_character, span.start_character + name.length)
              end
            end

            spans.uniq.sort_by { |span| [span.line, span.start_character] }
          end
        end
      end
    end
  end
end
