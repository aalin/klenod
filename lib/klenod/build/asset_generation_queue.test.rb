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

  def test_cpu_and_io_generation_have_independent_limits
    queue = Klenod::Build::AssetGenerationQueue.new(concurrency: 1, download_concurrency: 2)
    running = Hash.new(0)
    max_running = Hash.new(0)
    mutex = Mutex.new

    with_async_task do |task|
      tasks =
        [
          *2.times.map { task.async { track_generation(queue, :cpu, running, max_running, mutex) } },
          *3.times.map { task.async { track_generation(queue, :io, running, max_running, mutex) } }
        ]

      tasks.each(&:wait)
    end

    assert_equal(1, max_running.fetch(:cpu))
    assert_equal(2, max_running.fetch(:io))
  end

  def test_rejects_unknown_generation_kind
    queue = Klenod::Build::AssetGenerationQueue.new

    error = assert_raises(ArgumentError) { queue.run(kind: :network) { nil } }

    assert_equal("unknown asset generation queue kind: :network", error.message)
  end

  private

  def track_generation(queue, kind, running, max_running, mutex)
    queue.run(kind: kind) do
      mutex.synchronize do
        running[kind] += 1
        max_running[kind] = [max_running[kind], running[kind]].max
      end
      sleep(0.01)
      mutex.synchronize { running[kind] -= 1 }
    end.wait
  end

  def with_async_task(&block)
    enabled = Warning[:experimental]
    Warning[:experimental] = false
    Async(&block).wait
  ensure
    Warning[:experimental] = enabled
  end
end
