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
        def initialize(factory:, components_source: "{}")
          @factory = factory
          @components_source = components_source
        end

        def compile(source)
          document = Kramdown::Document.new(source, input: "GFM")
          compile_children(document.root.children)
        end

        private

        def compile_children(children, parent: nil)
          expressions = children.filter_map { |child| compile_node(child, parent: parent) }
          return "nil" if expressions.empty?
          return expressions.fetch(0) if expressions.length == 1

          "[#{expressions.join(", ")}]"
        end

        def compile_node(node, parent: nil, table_section: nil)
          case node.type
          when :root
            compile_children(node.children, parent: node)
          when :blank
            nil
          when :text
            node.value.inspect
          when :p
            return compile_children(node.children, parent: node) if node.options[:transparent]

            factory_call(:p, node.children, attrs: node.attr, parent: node)
          when :header
            factory_call(:"h#{node.options.fetch(:level)}", node.children, attrs: node.attr, parent: node)
          when :em, :strong, :a, :blockquote, :ul, :ol, :li, :table
            factory_call(node.type, node.children, attrs: node.attr, parent: node)
          when :thead, :tbody
            factory_call(node.type, node.children, attrs: node.attr, parent: node, table_section: node.type)
          when :tr
            factory_call(node.type, node.children, attrs: node.attr, parent: node, table_section: table_section)
          when :td
            factory_call((table_section == :thead) ? :th : :td, node.children, attrs: node.attr, parent: node, table_section: table_section)
          when :img, :hr, :br
            factory_call(node.type, [], attrs: node.attr, parent: node)
          when :codespan
            factory_call(:code, [node], raw_text: node.value, attrs: node.attr, parent: node)
          when :codeblock
            code = factory_call(:code, [node], raw_text: node.value, attrs: node.attr, parent: node)
            factory_call(:pre, [], child_sources: [code], parent: node)
          when :html_element
            factory_call(node.value.to_sym, node.children, attrs: node.attr, parent: node)
          when :raw
            node.value.to_s.inspect
          else
            compile_children(node.children, parent: node)
          end
        end

        def factory_call(tag, children, parent:, attrs: {}, raw_text: nil, child_sources: nil, table_section: nil)
          child_sources ||= raw_text.nil? ? children.filter_map { |child| compile_node(child, parent: parent, table_section: table_section) } : [raw_text.inspect]
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
      end
    end
  end
end
