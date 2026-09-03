# frozen_string_literal: true

module Example
  module Framework
    class MarkdownRenderer
      OMITTED_TAGS = %i[area base col embed input link meta param script source style template track wbr].to_set.freeze
      BLOCK_TAGS = %i[article body dd details dialog div dl dt fieldset figcaption figure footer form header main nav section summary].to_set.freeze
      INLINE_ESCAPES = /([\\`*_\[\]<>])/
      LITERAL_TOKEN = "\uE000klenod_markdown_literal_%d\uE001"

      def self.render(value)
        new.render(value)
      end

      def initialize
        @heading_level = 0
        @literal_blocks = []
      end

      def render(value)
        output = render_node(value)
        output = output.gsub(/[ \t]+\n/, "\n").gsub(/\n{3,}/, "\n\n").strip
        output = restore_literal_blocks(output)
        output.empty? ? "" : "#{output}\n"
      end

      private

      def render_node(value)
        case value
        when nil, false, H::Comment
          ""
        when H::Element
          render_element(value)
        when H::Text
          escape_text(value.value)
        when H::Fragment
          render_children(value.children)
        when H::ContextBoundary
          Context.with(**value.values) { render_children(value.children) }
        when H::Children
          render_children(value.to_a)
        when Array
          render_children(value)
        else
          escape_text(value)
        end
      end

      def render_element(element)
        tag = element.tag.to_sym
        return "" if OMITTED_TAGS.include?(tag)
        return heading(element, tag.to_s.delete_prefix("h").to_i) if tag.match?(/\Ah[1-6]\z/)

        case tag
        when :p
          block(render_children(element.children).strip)
        when :strong, :b
          wrap_inline("**", element)
        when :em, :i
          wrap_inline("*", element)
        when :del, :s
          wrap_inline("~~", element)
        when :a
          link(element)
        when :img
          image(element)
        when :code
          inline_code(H.text_content(element))
        when :pre
          fenced_code(element)
        when :ul
          list(element, ordered: false)
        when :ol
          list(element, ordered: true)
        when :li
          render_children(element.children)
        when :blockquote, :aside
          quote(element)
        when :br
          "  \n"
        when :hr
          block("---")
        when :details
          details(element)
        when :dl
          definition_list(element)
        when :dt, :dd
          render_children(element.children)
        when :table
          table(element)
        when :button, :label, :small, :span, :time
          render_children(element.children)
        else
          if BLOCK_TAGS.include?(tag)
            block(render_block_children(element.children).strip)
          else
            render_children(element.children)
          end
        end
      end

      def render_children(children)
        children.map { |child| render_node(child) }.join
      end

      def render_block_children(children)
        rendered_children = children.filter_map do |child|
          rendered = render_node(child)
          [child, rendered] unless rendered.empty?
        end

        rendered_children.each_with_index.each_with_object(+"") do |((child, rendered), index), output|
          previous_child, previous_rendered = rendered_children[index - 1] if index.positive?
          if previous_child.is_a?(H::Element) && child.is_a?(H::Element) && !previous_rendered.end_with?("\n") && !rendered.start_with?("\n")
            output << "\n"
          end
          output << rendered
        end
      end

      def heading(element, level)
        @heading_level = level
        block("#{"#" * level} #{render_children(element.children).strip}")
      end

      def details(element)
        parent_heading_level = @heading_level
        rendered_summary = false

        element.children.map do |child|
          if !rendered_summary && child.is_a?(H::Element) && child.tag.to_sym == :summary
            rendered_summary = true
            heading(child, [@heading_level + 1, 6].min)
          else
            render_node(child)
          end
        end.join
      ensure
        @heading_level = parent_heading_level
      end

      def wrap_inline(marker, element)
        content = render_children(element.children).strip
        content.empty? ? "" : "#{marker}#{content}#{marker}"
      end

      def link(element)
        props = H.localize_anchor_props(element.props.dup)
        label = render_children(element.children).strip
        href = prop(props, :href).to_s
        return label if href.empty?

        title = prop(props, :title)
        destination = escape_destination(href)
        suffix = title ? %( "#{title.to_s.gsub(/["\\]/) { |character| "\\#{character}" }}") : ""
        "[#{label}](#{destination}#{suffix})"
      end

      def image(element)
        alt = escape_text(prop(element.props, :alt).to_s)
        src = prop(element.props, :src).to_s
        return alt if src.empty?

        title = prop(element.props, :title)
        suffix = title ? %( "#{title.to_s.gsub(/["\\]/) { |character| "\\#{character}" }}") : ""
        "![#{alt}](#{escape_destination(src)}#{suffix})"
      end

      def inline_code(value)
        source = value.to_s
        fence = "`" * [longest_run(source, "`") + 1, 1].max
        padding = (source.start_with?("`", " ") || source.end_with?("`", " ")) ? " " : ""
        "#{fence}#{padding}#{source}#{padding}#{fence}"
      end

      def fenced_code(element)
        code = descendants(element).find { |child| child.tag.to_sym == :code }
        source = H.text_content(code || element).to_s
        language = language_from(code&.props || {})
        fence = "`" * [longest_run(source, "`") + 1, 3].max
        literal_block("#{fence}#{language}\n#{source.sub(/\n*\z/, "")}\n#{fence}")
      end

      def language_from(props)
        class_name = prop(props, :class).to_s
        language = class_name.split.find { |name| name.start_with?("language-") }&.delete_prefix("language-")
        language.to_s
      end

      def longest_run(value, character)
        value.scan(/#{Regexp.escape(character)}+/).map(&:length).max || 0
      end

      def list(element, ordered:)
        items = element.children.select { |child| child.is_a?(H::Element) && child.tag.to_sym == :li }
        lines = items.each_with_index.map do |item, index|
          marker = (ordered ? "#{index + 1}. " : "- ")
          indent(render_children(item.children).strip, marker)
        end
        block(lines.join("\n"))
      end

      def indent(content, marker)
        lines = content.lines(chomp: true)
        return marker.rstrip if lines.empty?

        continuation = " " * marker.length
        (["#{marker}#{lines.shift}"] + lines.map { |line| line.empty? ? "" : "#{continuation}#{line}" }).join("\n")
      end

      def quote(element)
        content = render_children(element.children).strip
        return "" if content.empty?

        quoted = content.lines(chomp: true).map { |line| line.empty? ? ">" : "> #{line}" }.join("\n")
        block(quoted)
      end

      def definition_list(element)
        entries = []
        previous_tag = nil

        element.children.each do |child|
          unless child.is_a?(H::Element) && %i[dt dd].include?(child.tag.to_sym)
            content = render_node(child).strip
            entries << content unless content.empty?
            next
          end

          tag = child.tag.to_sym
          entries << "" if tag == :dt && previous_tag == :dd
          content = render_children(child.children).strip
          entries << ((tag == :dd) ? definition(content) : content) unless content.empty?
          previous_tag = tag
        end

        block(entries.join("\n"))
      end

      def definition(content)
        lines = content.lines(chomp: true)
        first = lines.shift
        ([": #{first}"] + lines.map { |line| line.empty? ? "  " : "  #{line}" }).join("\n")
      end

      def table(element)
        rows = table_rows(element)
        return block(render_children(element.children).strip) if rows.empty?

        width = rows.map(&:length).max
        rows.each { |row| row.fill("", row.length...width) }
        header = rows.shift
        output = [table_row(header), table_row(Array.new(width, "---"))]
        output.concat(rows.map { |row| table_row(row) })
        block(output.join("\n"))
      end

      def table_rows(element)
        row_elements = descendants(element).select { |child| child.tag.to_sym == :tr }
        row_elements.map do |row|
          row.children.filter_map do |cell|
            next unless cell.is_a?(H::Element) && %i[th td].include?(cell.tag.to_sym)

            render_children(cell.children).strip.gsub(/\s+/, " ").gsub("|", "\\|")
          end
        end.reject(&:empty?)
      end

      def descendants(element)
        element.children.flat_map { descendant_elements(it) }
      end

      def descendant_elements(value)
        case value
        when H::Element
          [value, *descendants(value)]
        when H::Fragment
          value.children.flat_map { descendant_elements(it) }
        when H::Children
          value.flat_map { descendant_elements(it) }
        when Array
          value.flat_map { descendant_elements(it) }
        else
          []
        end
      end

      def table_row(cells)
        "| #{cells.join(" | ")} |"
      end

      def block(content)
        content.empty? ? "" : "\n\n#{content}\n\n"
      end

      def escape_text(value)
        value.to_s.gsub(/\s+/, " ").gsub(INLINE_ESCAPES, "\\\\\\1")
      end

      def escape_destination(value)
        value.gsub(/[()\\]/) { |character| "\\#{character}" }
      end

      def prop(props, name)
        props.fetch(name) { props.fetch(name.to_s, nil) }
      end

      def literal_block(value)
        index = @literal_blocks.length
        @literal_blocks << value
        block(format(LITERAL_TOKEN, index))
      end

      def restore_literal_blocks(output)
        @literal_blocks.each_with_index do |literal, index|
          output = output.gsub(format(LITERAL_TOKEN, index), literal)
        end
        output
      end
    end
  end
end
