# frozen_string_literal: true

module Example
  Context = Data.define(:request, :parent) do
    def self.current
      Fiber[CONTEXT_KEY]
    end

    def self.with(request: nil)
      previous = current
      Fiber[CONTEXT_KEY] = new(request || previous&.request, previous)
      yield
    ensure
      Fiber[CONTEXT_KEY] = previous
    end
  end
end
