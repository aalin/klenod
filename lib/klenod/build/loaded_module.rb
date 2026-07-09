# frozen_string_literal: true

module Klenod
  module Build
    class LoadedModule
      attr_reader :context, :id

      def initialize(context, id)
        @context = context
        @id = id
      end

      def record
        context.graph.records.fetch(id)
      end

      def exports
        context.exports(id)
      end

      def call(...)
        exports.call(...)
      end

      def assets(type: nil, content_type: nil, recursive: true)
        context.assets_for_module(id, type: type, content_type: content_type, recursive: recursive)
      end

      def to_s
        id.to_s
      end
    end
  end
end
