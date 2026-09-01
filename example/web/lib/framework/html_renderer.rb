# frozen_string_literal: true

require "cgi/escape"

module Example
  module HTMLRenderer
    VOID_TAGS = %i[area base br col embed hr img input link meta param source track wbr].to_set.freeze
    HTML_ESCAPE_PATTERN = /[&"<>]/

    class PreparedDocument
      include ResponseBody
      include Enumerable

      CHUNK_SIZE = 16 * 1024
      TITLE_OUTLET = Object.new.freeze

      def initialize(tokens, title)
        @tokens = tokens
        @title = title
        freeze
      end

      def each
        return enum_for(__method__) unless block_given?

        buffer = +""
        @tokens.each do |token|
          value = token.equal?(TITLE_OUTLET) ? @title : token
          next unless value

          offset = 0
          while offset < value.bytesize
            part = value.byteslice(offset, CHUNK_SIZE - buffer.bytesize)
            buffer << part
            offset += part.bytesize
            if buffer.bytesize == CHUNK_SIZE
              yield buffer.freeze
              buffer = +""
            end
          end
        end
        yield buffer.freeze unless buffer.empty?
        nil
      end

      def join
        output = +""
        each { |chunk| output << chunk }
        output
      end
    end

    class DocumentPreparer
      def initialize
        @tokens = []
      end

      def prepare(value)
        emit("<!doctype html>\n")
        append(value)
        tokens = @tokens.map { it.is_a?(String) ? it.freeze : it }.freeze
        PreparedDocument.new(tokens, @title)
      end

      private

      def append(value, svg: false)
        case value
        when nil, false
          nil
        when H::Element
          append_element(value, svg: svg)
        when H::Text
          emit(HTMLRenderer.escape_html(value.value))
        when H::Comment
          emit("<!--#{value.value.to_s.gsub("--", "- -")}-->")
        when H::Fragment
          value.children.each { append(it, svg: svg) }
        when H::ContextBoundary
          Context.with(**value.values) do
            value.children.each { append(it, svg: svg) }
          end
        when H::Children
          value.each { append(it, svg: svg) }
        when Array
          value.each { append(it, svg: svg) }
        else
          emit(HTMLRenderer.escape_html(value))
        end
      end

      def append_element(element, svg:)
        tag = element.tag.to_s
        props = element.props
        props = H.localize_anchor_props(props.dup) if !svg && element.tag == :a
        attributes = HTMLRenderer.rendered_attributes(props)

        if !svg && element.tag == :title
          title = "<#{tag}#{attributes}>"
          element.children.each { HTMLRenderer.append_rendered(title, it) }
          title << "</#{tag}>"
          @title = title.freeze
          unless @title_outlet
            @tokens << PreparedDocument::TITLE_OUTLET
            @title_outlet = true
          end
          return
        end

        emit("<#{tag}#{attributes}>")
        return if VOID_TAGS.include?(element.tag)

        child_svg = svg || element.tag == :svg
        element.children.each { append(it, svg: child_svg) }
        emit("</#{tag}>")
      end

      def emit(value)
        return if value.empty?

        if @tokens.last.is_a?(String)
          @tokens.last << value
        else
          @tokens << +value
        end
      end
    end

    module_function

    def render(value)
      output = +""
      append_rendered(output, value)
      output
    end

    def render_document(value)
      DocumentPreparer.new.prepare(value)
    end

    def append_rendered(output, value)
      case value
      when nil, false
        nil
      when H::Element
        append_element(output, value)
      when H::Text
        output << escape_html(value.value)
      when H::Comment
        output << "<!--"
        output << value.value.to_s.gsub("--", "- -")
        output << "-->"
      when H::Fragment
        value.children.each { |child| append_rendered(output, child) }
      when H::ContextBoundary
        Context.with(**value.values) do
          value.children.each { |child| append_rendered(output, child) }
        end
      when H::Children
        value.each { |child| append_rendered(output, child) }
      when Array
        value.each { |child| append_rendered(output, child) }
      else
        output << escape_html(value)
      end
    end

    def append_element(output, element)
      props = element.props
      props = H.localize_anchor_props(props.dup) if element.tag == :a
      attributes = rendered_attributes(props)

      output << "<#{element.tag}#{attributes}>"
      return if VOID_TAGS.include?(element.tag)

      element.children.each { |child| append_rendered(output, child) }
      output << "</#{element.tag}>"
    end

    def rendered_attributes(props)
      return "" if props.empty?

      output = +""
      props.each do |name, value|
        next if value.nil? || value == false

        output << " "
        output << (name.is_a?(Symbol) ? name.to_s : escape_html(name))
        next if value == true

        output << '="'
        output << escape_html(attribute_value(name, value))
        output << '"'
      end
      output
    end

    def attribute_value(name, value)
      return style_attribute(value) if value.is_a?(Hash) && name.to_sym == :style

      value
    end

    def style_attribute(value)
      value.filter_map do |property, property_value|
        next if property_value.nil? || property_value == false

        "#{property.to_s.tr("_", "-")}: #{property_value}"
      end.join("; ")
    end

    def escape_html(value)
      string = value.to_s
      return string unless string.match?(HTML_ESCAPE_PATTERN)

      CGI.escapeHTML(string)
    end
  end
end
