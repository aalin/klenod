# frozen_string_literal: true

module Example
  class Component
  end

  module H
    HtmlString = Class.new(String)
    VOID_TAGS = %i[area base br col embed hr img input link meta param source track wbr].freeze

    def self.[](tag, *children, **props)
      return tag.new(**props, children: children).render if tag.is_a?(Class)

      rendered_attributes =
        props
          .compact
          .reject { |_name, value| value == false }
          .map { |name, value| %( #{escape_html(name)}="#{escape_html(value)}") }
          .join

      return HtmlString.new("<#{tag}#{rendered_attributes}>") if VOID_TAGS.include?(tag)

      rendered_children = children.flatten.compact.map { |child| escape_html(child) }.join
      HtmlString.new("<#{tag}#{rendered_attributes}>#{rendered_children}</#{tag}>")
    end

    def self.escape_html(value)
      return value.to_s if value.is_a?(HtmlString)

      value
        .to_s
        .gsub("&", "&amp;")
        .gsub("<", "&lt;")
        .gsub(">", "&gt;")
        .gsub('"', "&quot;")
    end
  end
end
