# frozen_string_literal: true

require "async"
require "fileutils"
require "stringio"

module Klenod
  module Build
    class Asset
      attr_reader :logical_name, :content_hash, :output_path, :source_path, :content_type, :metadata, :queue_kind, :error

      def initialize(logical_name, content_hash, output_path, source_path, bytes, content_type, metadata, generator: nil, writer: nil, queue: nil, queue_kind: :cpu)
        @logical_name = logical_name
        @content_hash = content_hash
        @output_path = output_path
        @source_path = source_path
        @bytes = bytes
        @content_type = content_type
        @metadata = metadata
        @generator = generator
        @writer = writer
        @queue = queue
        @queue_kind = queue_kind
        @disk_path = nil
        @task = nil
        @mutex = Mutex.new
        @state = bytes.nil? ? :pending : :ready
        @error = nil
      end

      def self.generated(logical_name, content_hash, output_path, source_path, content_type, metadata, writer: nil, queue: nil, queue_kind: :cpu, &generator)
        new(logical_name, content_hash, output_path, source_path, nil, content_type, metadata, generator: generator, writer: writer, queue: queue, queue_kind: queue_kind)
      end

      def bytes
        wait
        @bytes || File.binread(@disk_path)
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

      def static?
        @generator.nil? && @writer.nil?
      end

      def generated?
        !static?
      end

      def write_to(path)
        path = path.to_s

        return skip_existing(path) if File.file?(path)

        task = start_write(path)
        task ? wait_for_task(task) : write_now_or_queued(path)
        raise error if failed?

        :written
      end

      private

      def start_generation
        @mutex.synchronize do
          return @task if @task
          return nil if ready?

          task = current_async_task
          return nil unless task

          @state = :running
          @task = queued_task(task) { generate_now }
        end
      end

      def start_write(path)
        @mutex.synchronize do
          return @task if @task
          return nil if ready? && materialized_for?(path)

          task = current_async_task
          return nil unless task

          @state = :running
          @task = queued_task(task) { write_now(path) }
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
        @bytes = generate_bytes
        @mutex.synchronize do
          @state = :ready
          @task = nil
        end
        self
      rescue => e
        fail_with(e)
        raise
      end

      def write_now(path)
        return skip_existing(path) if File.file?(path)
        return mark_disk_ready(path) if ready? && materialized_for?(path)

        temp_path = "#{path}.tmp.#{$$}.#{object_id}"
        FileUtils.mkdir_p(File.dirname(path))

        File.open(temp_path, "wb") do |file|
          if @writer
            @writer.call(file)
          else
            file.write(@bytes || generate_bytes)
          end
        end

        File.rename(temp_path, path)
        mark_disk_ready(path)
      rescue => e
        FileUtils.rm_f(temp_path) if temp_path
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

      def skip_existing(path)
        @mutex.synchronize do
          @disk_path = path
          @state = :ready
          @task = nil
        end
        :skipped
      end

      def mark_disk_ready(path)
        @mutex.synchronize do
          @disk_path = path
          @state = :ready
          @task = nil
        end
        :written
      end

      def materialized_for?(path)
        @disk_path == path
      end

      def current_async_task
        Async::Task.current
      rescue RuntimeError
        nil
      end

      def queued_task(task, &block)
        return @queue.run(kind: queue_kind, &block) if @queue

        task.async(&block)
      end

      def generate_now_or_queued
        return @queue.run(kind: queue_kind) { generate_now } if @queue

        generate_now
      end

      def write_now_or_queued(path)
        return @queue.run(kind: queue_kind) { write_now(path) } if @queue

        write_now(path)
      end

      def generate_bytes
        return @generator.call if @generator

        io = StringIO.new("".b)
        @writer.call(io)
        io.string
      end
    end
  end
end
