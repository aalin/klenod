# frozen_string_literal: true

module Example
  class Component
    def context
      Context.current
    end

    def request
      context&.request
    end

    def initialize(...)
    end
  end
end
