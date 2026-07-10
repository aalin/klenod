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

      def scheme
        path.include?(":") ? path.split(":", 2).fetch(0).to_sym : :app
      end

      def bare_path
        return path unless path.include?(":")

        path.split(":", 2).fetch(1)
      end
    end
  end
end
