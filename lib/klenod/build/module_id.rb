# frozen_string_literal: true

module Klenod
  module Build
    ModuleId = Data.define(:path, :query) do
      def self.parse(value)
        path, query = value.to_s.split("?", 2)
        new(path, query)
      end

      def to_s
        query ? "#{path}?#{query}" : path
      end

      def dirname
        File.dirname(path)
      end

      def extname
        File.extname(path)
      end
    end
  end
end
