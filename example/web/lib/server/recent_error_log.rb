# frozen_string_literal: true

require_relative "formatting"

module Example
  class RecentErrorLog
    DEFAULT_REPEAT_INTERVAL = 2.0

    def initialize(repeat_interval: DEFAULT_REPEAT_INTERVAL)
      @repeat_interval = repeat_interval
      @entries = {}
    end

    def remember(error, logged_at: current_time)
      entries[key(error)] = logged_at
    end

    def include?(error)
      entries.key?(key(error))
    end

    def recent?(error, now: current_time)
      logged_at = entries[key(error)]
      logged_at && (now - logged_at) < repeat_interval
    end

    def clear
      entries.clear
    end

    def warn_unless_recent(error, formatted)
      return if recent?(error) && !resolution_error?(error)

      warn formatted
      remember(error)
    end

    private

    attr_reader :entries, :repeat_interval

    def key(error)
      [error.class.name, ServerFormatting.strip_ansi(error.message)]
    end

    def resolution_error?(error)
      error.respond_to?(:resolution_failure?) && error.resolution_failure?
    end

    def current_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
