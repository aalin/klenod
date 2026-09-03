# frozen_string_literal: true

require_relative "rendered_fragment"

module Example
  module ComponentTestHelpers
    def render(component, *children, **props, &producer)
      html = H.render(H[component, *children, **props, &producer], class_names: :authored)
      RenderedFragment.new(html)
    end

    def with_context(**values, &block)
      Context.with(**values, &block)
    end
  end
end
