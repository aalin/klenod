# frozen_string_literal: true

previous_verbose = $VERBOSE
begin
  $VERBOSE = nil
  require "kramdown"
  require "kramdown-parser-gfm"
ensure
  $VERBOSE = previous_verbose
end

module Klenod
  module Build
    module Plugins
      class MarkdownCompiler
        ESCAPED_INTERPOLATION_SENTINEL = "\uE000klenod_escaped_interpolation\uE000"

        def initialize(factory:, components_source: "{}")
          @factory = factory
          @components_source = components_source
        end

        def compile(source, interpolate: false)
          source = protect_escaped_interpolation(source) if interpolate
          document = Kramdown::Document.new(source, input: "GFM")
          compile_children(document.root.children, interpolate: interpolate)
        end

        private

        def compile_children(children, parent: nil, interpolate: false)
          expressions = compile_child_expressions(children, parent: parent, interpolate: interpolate)
          return "nil" if expressions.empty?
          return expressions.fetch(0) if expressions.length == 1

          "[#{expressions.join(", ")}]"
        end

        def compile_child_expressions(children, parent:, interpolate:, table_section: nil)
          children.flat_map { |child| compile_node(child, parent: parent, table_section: table_section, interpolate: interpolate) }.compact
        end

        def compile_node(node, parent: nil, table_section: nil, interpolate: false)
          case node.type
          when :root
            [compile_children(node.children, parent: node, interpolate: interpolate)]
          when :blank
            nil
          when :text
            text_expressions(node.value, interpolate: interpolate)
          when :p
            return compile_child_expressions(node.children, parent: node, interpolate: interpolate) if node.options[:transparent]

            [factory_call(:p, node.children, attrs: node.attr, parent: node, interpolate: interpolate)]
          when :header
            [factory_call(:"h#{node.options.fetch(:level)}", node.children, attrs: node.attr, parent: node, interpolate: interpolate)]
          when :em, :strong, :a, :blockquote, :ul, :ol, :li, :table
            [factory_call(node.type, node.children, attrs: node.attr, parent: node, interpolate: interpolate)]
          when :thead, :tbody
            [factory_call(node.type, node.children, attrs: node.attr, parent: node, table_section: node.type, interpolate: interpolate)]
          when :tr
            [factory_call(node.type, node.children, attrs: node.attr, parent: node, table_section: table_section, interpolate: interpolate)]
          when :td
            [factory_call((table_section == :thead) ? :th : :td, node.children, attrs: node.attr, parent: node, table_section: table_section, interpolate: interpolate)]
          when :img, :hr, :br
            [factory_call(node.type, [], attrs: node.attr, parent: node, interpolate: interpolate)]
          when :codespan
            [factory_call(:code, [node], raw_text: node.value, attrs: node.attr, parent: node, interpolate: interpolate)]
          when :codeblock
            code = factory_call(:code, [node], raw_text: node.value, attrs: node.attr, parent: node, interpolate: interpolate)
            [factory_call(:pre, [], child_sources: [code], parent: node, interpolate: interpolate)]
          when :html_element
            [factory_call(node.value.to_sym, node.children, attrs: node.attr, parent: node, interpolate: interpolate)]
          when :raw
            [restore_escaped_interpolation(node.value.to_s).inspect]
          else
            [compile_children(node.children, parent: node, interpolate: interpolate)]
          end
        end

        def factory_call(tag, children, parent:, attrs: {}, raw_text: nil, child_sources: nil, table_section: nil, interpolate: false)
          child_sources ||=
            if raw_text.nil?
              compile_child_expressions(children, parent: parent, table_section: table_section, interpolate: interpolate)
            else
              [restore_escaped_interpolation(raw_text).inspect]
            end
          tag_source = tag_source(tag)
          parts = [tag_source, *child_sources]
          parts << "**#{attrs_source(attrs)}" unless attrs.empty?

          "#{@factory}[#{parts.join(", ")}]"
        end

        def tag_source(tag)
          "#{@components_source}.fetch(#{tag.inspect}, #{tag.inspect})"
        end

        def attrs_source(attrs)
          attrs.transform_keys(&:to_sym).inspect
        end

        def text_expressions(text, interpolate:)
          return [restore_escaped_interpolation(text).inspect] unless interpolate && text.include?("\#{")

          expressions = []
          buffer = +""
          index = 0

          while index < text.length
            if text[index, 2] == "\#{"
              expression, next_index = read_interpolation(text, index + 2)
              if expression
                expressions << restore_escaped_interpolation(buffer).inspect unless buffer.empty?
                buffer.clear
                expressions << "(#{expression})"
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

          expressions << restore_escaped_interpolation(buffer).inspect unless buffer.empty?
          expressions
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

        def protect_escaped_interpolation(source)
          source.gsub("\\\#{", ESCAPED_INTERPOLATION_SENTINEL)
        end

        def restore_escaped_interpolation(text)
          text.gsub(ESCAPED_INTERPOLATION_SENTINEL, "\#{")
        end
      end
    end
  end
end
