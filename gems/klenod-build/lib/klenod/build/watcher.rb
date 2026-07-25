# frozen_string_literal: true

require "listen"

module Klenod
  module Build
    UpdateEvent = Data.define(:changed_paths, :removed_paths, :graph_version, :result) do
      def asset_changes
        result.asset_changes
      end

      def asset_updates
        result.asset_updates
      end
    end

    class Watcher
      class PendingChanges
        def initialize
          @changed_paths = Set.new
          @removed_paths = Set.new
        end

        def add(changed_paths, removed_paths)
          changed_paths.each do |path|
            @changed_paths << path
            @removed_paths.delete(path)
          end

          removed_paths.each do |path|
            @removed_paths << path
            @changed_paths.delete(path)
          end
        end

        def empty?
          @changed_paths.empty? && @removed_paths.empty?
        end

        def normalized
          changed_paths = Set.new
          removed_paths = Set.new

          (@changed_paths + @removed_paths).each do |path|
            if File.exist?(path)
              changed_paths << path
            else
              removed_paths << path
            end
          end

          [changed_paths.to_a.freeze, removed_paths.to_a.freeze]
        end
      end

      def initialize(source_dir:, context:, debounce_interval: 0.1)
        @source_dir = source_dir
        @context = context
        @debounce_interval = debounce_interval
        @graph_version = 0
        @pending_changes = PendingChanges.new
        @pending_mutex = Mutex.new
        @pending_condition = ConditionVariable.new
        @last_change_at = nil
        @stopping = false
      end

      def start
        @worker_thread = Thread.new { process_pending_updates }
        @listener =
          Listen.to(@source_dir) do |modified, added, removed|
            enqueue_update(modified + added, removed)
          end
        @listener.start
      end

      def stop
        @listener&.stop
        @pending_mutex.synchronize do
          @stopping = true
          @pending_condition.broadcast
        end
        @worker_thread&.join
      end

      private

      def enqueue_update(changed_paths, removed_paths)
        @pending_mutex.synchronize do
          @pending_changes.add(changed_paths, removed_paths)
          @last_change_at = monotonic_time
          @pending_condition.signal
        end
      end

      def process_pending_updates
        loop do
          changed_paths, removed_paths = wait_for_pending_update
          break unless changed_paths

          emit_update(changed_paths, removed_paths)
        end
      end

      def wait_for_pending_update
        @pending_mutex.synchronize do
          @pending_condition.wait(@pending_mutex) while !@stopping && @pending_changes.empty?
          return nil if @stopping

          wait_for_debounce_window
          return nil if @stopping

          changes = @pending_changes
          @pending_changes = PendingChanges.new
          changes.normalized
        end
      end

      def wait_for_debounce_window
        loop do
          remaining = @debounce_interval - (monotonic_time - @last_change_at)
          break if remaining <= 0

          @pending_condition.wait(@pending_mutex, remaining)
          break if @stopping
        end
      end

      def emit_update(changed_paths, removed_paths)
        @graph_version += 1
        result = @context.invalidate_paths(changed_paths, removed_paths: removed_paths)

        @context.emit_update(UpdateEvent.new(changed_paths, removed_paths, @graph_version, result))
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
