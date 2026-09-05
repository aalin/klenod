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
        context = self
        while context
          return context.values.fetch(key) if context.values.key?(key)

          context = context.parent
        end

        available = available_keys.map(&:inspect).join(", ")
        message = "context variable #{key.inspect} is not set."
        message += " Available context values: #{available}." unless available.empty?
        raise KeyError, "#{message} Add it with Context.with(#{key}: ...)."
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

      private

      def available_keys
        values.keys | (parent ? parent.send(:available_keys) : [])
      end
    end
  end
end
