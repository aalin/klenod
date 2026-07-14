# frozen_string_literal: true

module Example
  Context = Data.define(:request, :parent) do
    def self.current
      Thread.current[CONTEXT_KEY]
    end

    def self.with(request: nil)
      previous = current
      Thread.current[CONTEXT_KEY] = new(request || previous&.request, previous)
      yield
    ensure
      Thread.current[CONTEXT_KEY] = previous
    end
  end
end
