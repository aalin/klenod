# frozen_string_literal: true

module Example
  class Route
    def localized_path(...)
      Context.current.routes.localized_path(...)
    end
  end
end
