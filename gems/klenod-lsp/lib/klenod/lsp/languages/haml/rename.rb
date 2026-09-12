# frozen_string_literal: true

require "klenod/build/plugins/haml_plugin"

require_relative "../../text"
require_relative "../imports"

module Klenod
  module LSP
    module Languages
      class Haml
        # Where a bound constant appears in a Haml document: the `%Name` tags
        # and the whole-word uses inside Ruby, meaning `:ruby` filters, script
        # lines, tag attributes, and printed tag content. Plain text keeps
        # its words.
        module Rename
          TAG_HEAD = /%[A-Za-z][\w:-]*(?:[.#][\w-]+)*/

          module_function

          def spans(source, name)
            lines = source.lines(chomp: true)
            spans = []

            each_ruby_region(source, lines) do |line_index, start_character, text|
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

          # Yields (line index, column offset, text) for every stretch of Ruby.
          # Falls back to script lines when the document does not parse.
          def each_ruby_region(source, lines, &block)
            root = Klenod::Build::Plugins::HamlPlugin.parse_haml(source)
            each_node_region(root.children, lines, &block)
          rescue Klenod::Build::Error
            lines.each_with_index do |line_text, index|
              yield index, 0, line_text if line_text.match?(/\A\s*[-=~]/)
            end
          end

          def each_node_region(nodes, lines, &block)
            nodes.each do |node|
              line_index = node.line - 1
              case node.type
              when :filter
                if node.value[:name] == "ruby"
                  node.value.fetch(:text).to_s.each_line.with_index(node.line) { |_text, index| yield index, 0, lines[index].to_s }
                end
              when :script, :silent_script
                yield line_index, 0, lines[line_index].to_s
              when :tag
                tag_region(node, lines[line_index].to_s, line_index, &block)
              end
              each_node_region(node.children, lines, &block) unless node.type == :filter
            end
          end

          def tag_region(node, line_text, line_index)
            head = TAG_HEAD.match(line_text)
            return unless head

            rest_start = head.end(0)
            rest = line_text[rest_start..].to_s
            if node.value[:parse]
              yield line_index, rest_start, rest
            else
              attribute_regions(rest).each { |offset, text| yield line_index, rest_start + offset, text }
            end
          end

          # Attribute hashes and parenthesized attributes, matched by nesting.
          def attribute_regions(rest)
            regions = []
            index = 0
            while index < rest.length
              opener = rest[index]
              if (closer = {"{" => "}", "(" => ")", "[" => "]"}[opener])
                depth = 0
                start = index
                while index < rest.length
                  depth += 1 if rest[index] == opener
                  depth -= 1 if rest[index] == closer
                  index += 1
                  break if depth.zero?
                end
                regions << [start, rest[start...index]]
              else
                break unless opener =~ /\s/ || regions.empty?

                index += 1
              end
            end
            regions
          end
        end
      end
    end
  end
end
