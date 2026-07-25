# frozen_string_literal: true

require "cgi/escape"

module Example
  module H
    HtmlString = Class.new(String)
    VOID_TAGS = %i[area base br col embed hr img input link meta param source track wbr].freeze
    HTML_ESCAPE_PATTERN = /[&"<>]/

    def self.[](tag, *children, **props)
      return render_component(tag, **props, children: children) if tag.is_a?(Class)

      props = localize_anchor_props(props) if tag == :a
      rendered_attributes = rendered_attributes(props)

      return HtmlString.new("<#{tag}#{rendered_attributes}>") if VOID_TAGS.include?(tag)

      rendered_children = +""
      append_children(rendered_children, children)
      HtmlString.new("<#{tag}#{rendered_attributes}>#{rendered_children}</#{tag}>")
    end

    def self.append_children(output, children)
      children.each do |child|
        case child
        when nil
          next
        when Array
          append_children(output, child)
        else
          output << escape_html(child)
        end
      end
    end

    def self.escape_html(value)
      return value.to_s if value.is_a?(HtmlString)

      string = value.to_s
      return string unless string.match?(HTML_ESCAPE_PATTERN)

      CGI.escapeHTML(string)
    end

    def self.rendered_attributes(props)
      return "" if props.empty?

      output = +""
      props.each do |name, value|
        next if value.nil? || value == false

        output << rendered_attribute(name, value)
      end
      output
    end

    def self.rendered_attribute(name, value)
      return " #{escape_html(name)}" if value == true

      %( #{escape_html(name)}="#{escape_html(value)}")
    end

    def self.localize_anchor_props(props)
      href = props[:href]
      return props unless localizable_href?(href)

      path, suffix = href.to_s.match(/\A([^?#]*)(.*)\z/).captures
      routes = Context.current&.routes
      return props unless routes

      locale = props[:hreflang] || Context.current&.request&.locale
      props[:href] = "#{routes.localized_href(path, locale: locale)}#{suffix}"
      props
    end

    def self.localizable_href?(href)
      value = href.to_s
      return false unless value.start_with?("/")
      return false if value.start_with?("//")
      return false if value == "/assets" || value.start_with?("/assets/")

      true
    end

    def self.render_component(tag, **props)
      if tag.respond_to?(:instantiate)
        tag.instantiate(**props).render
      else
        tag.new(**props).render
      end
    end
  end
end
