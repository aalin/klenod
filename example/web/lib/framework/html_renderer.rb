# frozen_string_literal: true

require "cgi/escape"

module Example
  module HTMLRenderer
    VOID_TAGS = %i[area base br col embed hr img input link meta param source track wbr].to_set.freeze
    HTML_ESCAPE_PATTERN = /[&"<>]/

    module_function

    def render(value)
      output = +""
      append_rendered(output, value)
      output
    end

    def render_document(value)
      "<!doctype html>\n#{render(value)}"
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
