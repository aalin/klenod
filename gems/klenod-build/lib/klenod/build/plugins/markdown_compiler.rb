# frozen_string_literal: true

previous_verbose = $VERBOSE
begin
  $VERBOSE = nil
  require "kramdown"
  require "kramdown-parser-gfm"
ensure
  $VERBOSE = previous_verbose
end

require_relative "text_interpolation"

module Klenod
  module Build
    module Plugins
      class MarkdownCompiler
        def initialize(factory:, components_source: "{}")
          @factory = factory
          @components_source = components_source
        end

        def compile(source, interpolate: false)
          @interpolation = TextInterpolation::Source.new(source) if interpolate
          document = Kramdown::Document.new(@interpolation&.text || source, input: "GFM", hard_wrap: false)
          compile_children(document.root.children)
        ensure
          @interpolation = nil
        end

        private

        def compile_children(children, parent: nil)
          expressions = compile_child_expressions(children, parent: parent)
          return "nil" if expressions.empty?
          return expressions.fetch(0) if expressions.length == 1

          "[#{expressions.join(", ")}]"
        end

        def compile_child_expressions(children, parent:, table_section: nil)
          children.flat_map { |child| compile_node(child, parent: parent, table_section: table_section) }.compact
        end

        def compile_node(node, parent: nil, table_section: nil)
          case node.type
          when :root
            [compile_children(node.children, parent: node)]
          when :blank
            nil
          when :text
            text_expressions(node.value)
          when :p
            return compile_child_expressions(node.children, parent: node) if node.options[:transparent]

            [factory_call(:p, node.children, attrs: node.attr, parent: node)]
          when :header
            [factory_call(:"h#{node.options.fetch(:level)}", node.children, attrs: header_attrs(node), parent: node)]
          when :em, :strong, :a, :blockquote, :ul, :ol, :li, :table
            [factory_call(node.type, node.children, attrs: node.attr, parent: node)]
          when :thead, :tbody
            [factory_call(node.type, node.children, attrs: node.attr, parent: node, table_section: node.type)]
          when :tr
            [factory_call(node.type, node.children, attrs: node.attr, parent: node, table_section: table_section)]
          when :td
            [factory_call((table_section == :thead) ? :th : :td, node.children, attrs: node.attr, parent: node, table_section: table_section)]
          when :img, :hr, :br
            [factory_call(node.type, [], attrs: node.attr, parent: node)]
          when :codespan
            [factory_call(:code, [node], raw_text: node.value, attrs: node.attr, parent: node)]
          when :codeblock
            code = factory_call(:code, [node], raw_text: node.value, attrs: node.attr, parent: node)
            [factory_call(:pre, [], child_sources: [code], parent: node)]
          when :html_element
            [factory_call(node.value.to_sym, node.children, attrs: node.attr, parent: node)]
          when :raw
            [literal_text(node.value.to_s).inspect]
          else
            [compile_children(node.children, parent: node)]
          end
        end

        def factory_call(tag, children, parent:, attrs: {}, raw_text: nil, child_sources: nil, table_section: nil)
          child_sources ||=
            if raw_text.nil?
              compile_child_expressions(children, parent: parent, table_section: table_section)
            else
              [literal_text(raw_text).inspect]
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
          pairs = attrs.map do |name, value|
            value_source = value.is_a?(String) ? string_source(value) : value.inspect
            "#{name.to_sym.inspect} => #{value_source}"
          end

          "{#{pairs.join(", ")}}"
        end

        # Kramdown derives heading IDs from text that still contains
        # interpolation tokens, which leaves stray separators behind.
        def header_attrs(node)
          id = node.attr["id"]
          return node.attr unless id && @interpolation&.interpolated?(node.options[:raw_text].to_s)

          node.attr.merge("id" => id.gsub(/-{2,}/, "-").delete_prefix("-").delete_suffix("-"))
        end

        def text_expressions(text)
          @interpolation ? @interpolation.expressions(text) : [text.inspect]
        end

        def string_source(text)
          @interpolation ? @interpolation.string_source(text) : text.inspect
        end

        def literal_text(text)
          @interpolation ? @interpolation.literal(text) : text
        end
      end
    end
  end
end
