# frozen_string_literal: true

require "async"
require "async/semaphore"
require "etc"

module Klenod
  module Build
    class AssetGenerationQueue
      DEFAULT_CONCURRENCY = [Etc.nprocessors / 2, 2].max
      DEFAULT_DOWNLOAD_CONCURRENCY = 4

      attr_reader :concurrency, :download_concurrency

      def initialize(concurrency: DEFAULT_CONCURRENCY, download_concurrency: DEFAULT_DOWNLOAD_CONCURRENCY)
        @concurrency = Integer(concurrency)
        @download_concurrency = Integer(download_concurrency)
        raise ArgumentError, "concurrency must be positive" unless @concurrency.positive?
        raise ArgumentError, "download_concurrency must be positive" unless @download_concurrency.positive?

        @semaphores = {
          cpu: Async::Semaphore.new(@concurrency),
          io: Async::Semaphore.new(@download_concurrency)
        }
      end

      def run(kind: :cpu, &block)
        semaphore = semaphore_for(kind)
        task = current_async_task
        return semaphore.acquire { block.call } unless task

        semaphore.async(parent: task) { block.call }
      end

      private

      def semaphore_for(kind)
        @semaphores.fetch(kind) do
          raise ArgumentError, "unknown asset generation queue kind: #{kind.inspect}"
        end
      end

      def current_async_task
        Async::Task.current
      rescue RuntimeError
        nil
      end
    end
  end
end
