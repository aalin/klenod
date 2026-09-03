# frozen_string_literal: true

module Example
  module Framework
    Context = Data.define(:values, :parent) do
      def self.current
        Fiber[CONTEXT_KEY]
      end

      def self.with(**values)
        previous = current
        Fiber[CONTEXT_KEY] = new(values.freeze, previous)
        yield
      ensure
        Fiber[CONTEXT_KEY] = previous
      end

      def fetch(name)
        key = name.to_sym
        return values.fetch(key) if values.key?(key)
        return parent.fetch(key) if parent

        raise KeyError, "context variable not found: #{key.inspect}"
      end

      def [](name)
        fetch(name)
      end

      def request
        fetch(:request)
      end

      def routes
        fetch(:routes)
      end
    end
  end
end
