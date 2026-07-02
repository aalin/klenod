# frozen_string_literal: true

require "minitest/autorun"

require_relative "watcher"

class Klenod::Dev::Watcher::Test < Minitest::Test
  def test_update_event_carries_invalidation_result
    result = Object.new
    event = Klenod::Dev::UpdateEvent.new(["a.rb"], ["b.rb"], 1, result)

    assert_equal(["a.rb"], event.changed_paths)
    assert_equal(["b.rb"], event.removed_paths)
    assert_equal(1, event.graph_version)
    assert_same(result, event.result)
  end
end
