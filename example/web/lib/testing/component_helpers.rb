# frozen_string_literal: true

module Example
  module ComponentTestHelpers
    def render(component, *children, **props, &producer)
      H.render(H[component, *children, **props, &producer])
    end

    def with_context(**values, &block)
      Context.with(**values, &block)
    end
  end
end
