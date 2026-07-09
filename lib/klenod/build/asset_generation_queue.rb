# frozen_string_literal: true

require "async"
require "async/semaphore"
require "etc"

module Klenod
  module Build
    class AssetGenerationQueue
      DEFAULT_CONCURRENCY = [Etc.nprocessors / 2, 2].max

      attr_reader :concurrency

      def initialize(concurrency: DEFAULT_CONCURRENCY)
        @concurrency = Integer(concurrency)
        raise ArgumentError, "concurrency must be positive" unless @concurrency.positive?

        @semaphore = Async::Semaphore.new(@concurrency)
      end

      def run(&block)
        task = current_async_task
        return @semaphore.acquire { block.call } unless task

        @semaphore.async(parent: task) { block.call }
      end

      private

      def current_async_task
        Async::Task.current
      rescue RuntimeError
        nil
      end
    end
  end
end
