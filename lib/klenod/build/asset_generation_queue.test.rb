# frozen_string_literal: true

require "async"
require "minitest/autorun"

require_relative "asset"
require_relative "asset_generation_queue"

class Klenod::Build::AssetGenerationQueue::Test < Minitest::Test
  def test_limits_concurrent_generation
    queue = Klenod::Build::AssetGenerationQueue.new(concurrency: 2)
    running = 0
    max_running = 0
    mutex = Mutex.new

    with_async_task do |task|
      tasks =
        5.times.map do
          task.async do
            queue.run do
              mutex.synchronize do
                running += 1
                max_running = [max_running, running].max
              end
              sleep(0.01)
              mutex.synchronize { running -= 1 }
            end.wait
          end
        end

      tasks.each(&:wait)
    end

    assert_equal(2, max_running)
  end

  def test_generated_assets_use_queue_limit
    queue = Klenod::Build::AssetGenerationQueue.new(concurrency: 1)
    running = 0
    max_running = 0
    mutex = Mutex.new
    assets =
      3.times.map do |index|
        Klenod::Build::Asset.generated(
          "images/#{index}.png",
          index.to_s,
          "/assets/#{index}.png",
          nil,
          "image/png",
          {},
          queue: queue
        ) do
          mutex.synchronize do
            running += 1
            max_running = [max_running, running].max
          end
          sleep(0.01)
          mutex.synchronize { running -= 1 }
          "bytes #{index}"
        end
      end

    with_async_task do |task|
      assets.map { |asset| task.async { asset.bytes } }.each(&:wait)
    end

    assert_equal(1, max_running)
    assert_equal(["bytes 0", "bytes 1", "bytes 2"], assets.map(&:bytes))
  end

  private

  def with_async_task(&block)
    enabled = Warning[:experimental]
    Warning[:experimental] = false
    Async(&block).wait
  ensure
    Warning[:experimental] = enabled
  end
end
