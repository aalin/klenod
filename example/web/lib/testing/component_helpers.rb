# frozen_string_literal: true

require_relative "rendered_fragment"

module Example
  module Testing
    module ComponentTestHelpers
      FRAMEWORK_CONSTANTS = {
        Request: Framework::Request,
        Response: Framework::Response
      }.freeze

      def render(component, *children, **props, &producer)
        html = Framework::H.render(Framework::H[component, *children, **props, &producer], class_names: :authored)
        RenderedFragment.new(html)
      end

      def with_context(**values, &block)
        Framework::Context.with(**values, &block)
      end
    end
  end
end
