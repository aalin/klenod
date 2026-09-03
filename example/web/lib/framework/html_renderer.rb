# frozen_string_literal: true

require "cgi/escape"

module Example
  module Framework
    module HTMLRenderer
      VOID_TAGS = %i[area base br col embed hr img input link meta param source track wbr].to_set.freeze
      HTML_ESCAPE_PATTERN = /[&"<>]/
      SCOPED_CLASS_NAME = /\A.+\.(?<name>[^.?]+)\?[^?]+\z/
      SCOPED_TAG_NAME = /\A.+_[^?]+\?[^?]+\z/

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
        def initialize(class_names: nil)
          @tokens = []
          @class_names = class_names
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
          attributes = HTMLRenderer.rendered_attributes(props, class_names: @class_names)

          if !svg && element.tag == :title
            title = "<#{tag}#{attributes}>"
            element.children.each { HTMLRenderer.append_rendered(title, it, class_names: @class_names) }
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

      def render(value, class_names: nil)
        output = +""
        append_rendered(output, value, class_names: class_names)
        output
      end

      def render_document(value, class_names: nil)
        DocumentPreparer.new(class_names: class_names).prepare(value)
      end

      def append_rendered(output, value, class_names: nil)
        case value
        when nil, false
          nil
        when H::Element
          append_element(output, value, class_names: class_names)
        when H::Text
          output << escape_html(value.value)
        when H::Comment
          output << "<!--"
          output << value.value.to_s.gsub("--", "- -")
          output << "-->"
        when H::Fragment
          value.children.each { |child| append_rendered(output, child, class_names: class_names) }
        when H::ContextBoundary
          Context.with(**value.values) do
            value.children.each { |child| append_rendered(output, child, class_names: class_names) }
          end
        when H::Children
          value.each { |child| append_rendered(output, child, class_names: class_names) }
        when Array
          value.each { |child| append_rendered(output, child, class_names: class_names) }
        else
          output << escape_html(value)
        end
      end

      def append_element(output, element, class_names: nil)
        props = element.props
        props = H.localize_anchor_props(props.dup) if element.tag == :a
        attributes = rendered_attributes(props, class_names: class_names)

        output << "<#{element.tag}#{attributes}>"
        return if VOID_TAGS.include?(element.tag)

        element.children.each { |child| append_rendered(output, child, class_names: class_names) }
        output << "</#{element.tag}>"
      end

      def rendered_attributes(props, class_names: nil)
        return "" if props.empty?

        output = +""
        props.each do |name, value|
          value = authored_class_names(value) if class_names == :authored && name.to_sym == :class
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

      def authored_class_names(value)
        names = value.to_s.split.filter_map do |class_name|
          match = class_name.match(SCOPED_CLASS_NAME)
          next match[:name] if match
          next if class_name.match?(SCOPED_TAG_NAME)

          class_name
        end
        names.uniq!
        names.join(" ") unless names.empty?
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
end
