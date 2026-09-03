# frozen_string_literal: true

module Example
  module Framework
    class Route
      def localized_path(...)
        Context.current.routes.localized_path(...)
      end
    end
  end
end
