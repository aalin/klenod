# frozen_string_literal: true

module Klenod
  module Build
    class Profiler
      Event = Data.define(:name, :duration, :metadata)

      def initialize(enabled: false, store_events: true)
        @enabled = enabled
        @events = store_events ? [] : nil
        @totals = Hash.new(0.0)
        @totals_by_plugin = Hash.new(0.0)
      end

      def enabled?
        @enabled
      end

      def events
        @events || []
      end

      def measure(name, metadata = nil)
        return yield unless enabled?

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = yield
        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        record(name, duration, metadata || {})
        result
      rescue
        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at if started_at
        record(name, duration, (metadata || {}).merge(error: true)) if duration
        raise
      end

      def totals
        @totals.dup
      end

      def totals_by_plugin
        @totals_by_plugin.dup
      end

      private

      def record(name, duration, metadata)
        @events << Event.new(name, duration, metadata) if @events
        @totals[name] += duration

        plugin = metadata[:plugin]
        @totals_by_plugin[[name, plugin]] += duration if plugin
      end
    end
  end
end
