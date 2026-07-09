# frozen_string_literal: true

require "listen"

module Klenod
  module Dev
    UpdateEvent = Data.define(:changed_paths, :removed_paths, :graph_version, :result) do
      def asset_changes
        result.asset_changes
      end
    end

    class Watcher
      def initialize(source_dir:, context:)
        @source_dir = source_dir
        @context = context
        @graph_version = 0
      end

      def start
        @listener =
          Listen.to(@source_dir) do |modified, added, removed|
            @graph_version += 1
            changed_paths = (modified + added).freeze
            removed_paths = removed.freeze
            result = @context.invalidate_paths(changed_paths, removed_paths: removed_paths)

            @context.emit_update(UpdateEvent.new(changed_paths, removed_paths, @graph_version, result))
          end
        @listener.start
      end

      def stop
        @listener&.stop
      end
    end
  end
end
