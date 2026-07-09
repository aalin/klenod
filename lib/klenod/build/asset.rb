# frozen_string_literal: true

require "async"

module Klenod
  module Build
    class Asset
      attr_reader :logical_name, :content_hash, :output_path, :source_path, :content_type, :metadata, :error

      def initialize(logical_name, content_hash, output_path, source_path, bytes, content_type, metadata, generator: nil, queue: nil)
        @logical_name = logical_name
        @content_hash = content_hash
        @output_path = output_path
        @source_path = source_path
        @bytes = bytes
        @content_type = content_type
        @metadata = metadata
        @generator = generator
        @queue = queue
        @task = nil
        @mutex = Mutex.new
        @state = bytes.nil? ? :pending : :ready
        @error = nil
      end

      def self.generated(logical_name, content_hash, output_path, source_path, content_type, metadata, queue: nil, &generator)
        new(logical_name, content_hash, output_path, source_path, nil, content_type, metadata, generator: generator, queue: queue)
      end

      def bytes
        wait
        @bytes
      end

      def wait
        return self if ready?
        raise error if failed?

        task = start_generation
        task ? wait_for_task(task) : generate_now_or_queued
        raise error if failed?

        self
      end

      def ready?
        @state == :ready
      end

      def pending?
        @state == :pending
      end

      def running?
        @state == :running
      end

      def failed?
        @state == :failed
      end

      private

      def start_generation
        @mutex.synchronize do
          return @task if @task
          return nil if ready?

          task = current_async_task
          return nil unless task

          @state = :running
          @task = queued_generation_task(task)
        end
      end

      def wait_for_task(task)
        task.wait
      rescue => e
        fail_with(e)
        raise
      end

      def generate_now
        return self if ready?

        @mutex.synchronize do
          return self if ready?

          @state = :running
        end
        @bytes = @generator.call
        @mutex.synchronize do
          @state = :ready
          @task = nil
        end
        self
      rescue => e
        fail_with(e)
        raise
      end

      def fail_with(error)
        @mutex.synchronize do
          @error ||= error
          @state = :failed
          @task = nil
        end
      end

      def current_async_task
        Async::Task.current
      rescue RuntimeError
        nil
      end

      def queued_generation_task(task)
        return @queue.run { generate_now } if @queue

        task.async { generate_now }
      end

      def generate_now_or_queued
        return @queue.run { generate_now } if @queue

        generate_now
      end
    end
  end
end
