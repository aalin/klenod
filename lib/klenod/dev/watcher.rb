# frozen_string_literal: true

require "listen"

module Klenod
  module Dev
    UpdateEvent = Data.define(:changed_paths, :removed_paths, :graph_version)

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
            @context.emit_update(UpdateEvent.new((modified + added).freeze, removed.freeze, @graph_version))
          end
        @listener.start
      end

      def stop
        @listener&.stop
      end
    end
  end
end
