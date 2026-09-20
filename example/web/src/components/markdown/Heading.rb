# frozen_string_literal: true

Styles = import("./Heading.css")

module MarkdownHeading
  class Base < Example::Framework::Component
    def render
      props = @__props.except(:children, :slots, :level)
      tag = :"h#{self.class::LEVEL}"
      classes = [props.delete(:class), Styles.fetch(:"__#{tag}")].compact.join(" ")
      props[:class] = classes unless classes.empty?

      Example::Framework::H[
        tag,
        *@__props.fetch(:children).to_a,
        **props
      ]
    end
  end

  (1..6).each do |level|
    const_set("H#{level}", Class.new(Base) { const_set(:LEVEL, level) })
  end
end

Default = MarkdownHeading
