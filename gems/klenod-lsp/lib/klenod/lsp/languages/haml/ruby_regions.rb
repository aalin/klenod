# frozen_string_literal: true

require "klenod/build/plugins/haml_plugin"

module Klenod
  module LSP
    module Languages
      class Haml
        # Executable Ruby regions in a Haml document: Ruby filters, script
        # lines, tag attributes, and printed tag content.
        module RubyRegions
          # `%name.class#id`, or `.class#id` for an implicit `%div`.
          TAG_HEAD = /\A\s*(?:%[A-Za-z][\w:-]*(?:[.#][\w-]+)*|(?:[.#][\w-]+)+)/

          module_function

          def each(source, lines, &block)
            root = Klenod::Build::Plugins::HamlPlugin.parse_haml(source)
            each_node(root.children, lines, &block)
          rescue Klenod::Build::Error
            lines.each_with_index do |line_text, index|
              next unless line_text.match?(/\A\s*(?:-(?!#)|[=~])/)

              yield index, 0, line_text
            end
          end

          def each_node(nodes, lines, &block)
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
                tag(node, lines, line_index, &block)
              end
              each_node(node.children, lines, &block) unless node.type == :filter
            end
          end

          def tag(node, lines, line_index, &block)
            line_text = lines[line_index].to_s
            head = TAG_HEAD.match(line_text)
            return unless head

            rest_start = head.end(0)
            rest = line_text[rest_start..].to_s
            regions = attribute_regions(rest)
            if node.value[:parse]
              yield line_index, rest_start, rest
            else
              regions.each { |offset, text| yield line_index, rest_start + offset, text }
            end
            continuation(lines, line_index + 1, regions.last&.last, parse: node.value[:parse], &block)
          end

          # The lines of an attribute region left open on the tag line, up to
          # and including its closer. A tag printing Ruby content keeps the
          # rest of the closing line too: `}= value`.
          def continuation(lines, line_index, region, parse: false)
            return unless region

            opener = region[0]
            closer = {"{" => "}", "(" => ")", "[" => "]"}.fetch(opener)
            depth = region.count(opener) - region.count(closer)
            while depth.positive? && line_index < lines.length
              line_text = lines[line_index].to_s
              length = line_text.length
              line_text.each_char.with_index do |char, index|
                depth += 1 if char == opener
                depth -= 1 if char == closer
                next unless depth.zero?

                length = index + 1 unless parse
                break
              end
              yield line_index, 0, line_text[0...length]
              line_index += 1
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
