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
          source = TextInterpolation.protect_escapes(source) if interpolate
          document = Kramdown::Document.new(source, input: "GFM", hard_wrap: false)
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
          parts << "**#{attrs_source(attrs, interpolate: interpolate)}" unless attrs.empty?

          "#{@factory}[#{parts.join(", ")}]"
        end

        def tag_source(tag)
          "#{@components_source}.fetch(#{tag.inspect}, #{tag.inspect})"
        end

        def attrs_source(attrs, interpolate: false)
          pairs = attrs.map do |name, value|
            value_source =
              if value.is_a?(String)
                interpolate ? TextInterpolation.string_source(value) : restore_escaped_interpolation(value).inspect
              else
                value.inspect
              end
            "#{name.to_sym.inspect} => #{value_source}"
          end

          "{#{pairs.join(", ")}}"
        end

        def text_expressions(text, interpolate:)
          return [restore_escaped_interpolation(text).inspect] unless interpolate

          TextInterpolation.expressions(text)
        end

        def restore_escaped_interpolation(text)
          TextInterpolation.restore_escapes(text)
        end
      end
    end
  end
end
