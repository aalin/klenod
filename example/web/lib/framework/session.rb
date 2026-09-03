# frozen_string_literal: true

module Example
  module Framework
    class Session
      def initialize(values = {})
        @values = values
        @dirty = false
      end

      def [](key)
        @values[key]
      end

      def []=(key, value)
        @dirty = true unless @values[key] == value
        @values[key] = value
      end

      def fetch(...)
        @values.fetch(...)
      end

      def delete(key)
        @dirty = true if @values.key?(key)
        @values.delete(key)
      end

      def dirty?
        @dirty
      end

      def to_h
        @values
      end
    end
  end
end
