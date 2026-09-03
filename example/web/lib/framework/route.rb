# frozen_string_literal: true

module Example
  module Framework
    class Route
      Response = Framework::Response

      def localized_path(...)
        Context.current.routes.localized_path(...)
      end
    end
  end
end
