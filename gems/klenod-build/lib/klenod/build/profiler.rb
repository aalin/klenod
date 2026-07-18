# frozen_string_literal: true

module Klenod
  module Build
    class Profiler
      Event = Data.define(:name, :duration, :metadata)

      attr_reader :events

      def initialize(enabled: false)
        @enabled = enabled
        @events = []
      end

      def enabled?
        @enabled
      end

      def measure(name, metadata = nil)
        return yield unless enabled?

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = yield
        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        @events << Event.new(name, duration, metadata || {})
        result
      rescue
        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at if started_at
        @events << Event.new(name, duration, (metadata || {}).merge(error: true)) if duration
        raise
      end

      def totals
        @events.each_with_object(Hash.new(0.0)) do |event, index|
          index[event.name] += event.duration
        end
      end

      def totals_by_plugin
        @events.each_with_object(Hash.new(0.0)) do |event, index|
          plugin = event.metadata[:plugin]
          index[[event.name, plugin]] += event.duration if plugin
        end
      end
    end
  end
end
