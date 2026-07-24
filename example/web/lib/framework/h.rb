# frozen_string_literal: true

require "cgi/escape"

module Example
  module H
    HtmlString = Class.new(String)
    VOID_TAGS = %i[area base br col embed hr img input link meta param source track wbr].freeze

    def self.[](tag, *children, **props)
      return render_component(tag, **props, children: children) if tag.is_a?(Class)

      props = localize_anchor_props(props) if tag == :a
      rendered_attributes =
        props
          .compact
          .reject { |_name, value| value == false }
          .map { |name, value| rendered_attribute(name, value) }
          .join

      return HtmlString.new("<#{tag}#{rendered_attributes}>") if VOID_TAGS.include?(tag)

      rendered_children = children.flatten.compact.map { |child| escape_html(child) }.join
      HtmlString.new("<#{tag}#{rendered_attributes}>#{rendered_children}</#{tag}>")
    end

    def self.escape_html(value)
      return value.to_s if value.is_a?(HtmlString)

      CGI.escapeHTML(value.to_s)
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
      props.merge(href: "#{routes.localized_href(path, locale: locale)}#{suffix}")
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
