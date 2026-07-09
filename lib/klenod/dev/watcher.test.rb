# frozen_string_literal: true

require "minitest/autorun"

require_relative "../build/asset"
require_relative "../build/invalidation_result"
require_relative "watcher"

class Klenod::Dev::Watcher::Test < Minitest::Test
  def test_update_event_carries_invalidation_result
    new_asset =
      Klenod::Build::Asset.new(
        "styles/new.css",
        "new",
        "/assets/new.css",
        nil,
        "body {}",
        "text/css",
        {}
      )
    old_asset =
      Klenod::Build::Asset.new(
        "styles/old.css",
        "old",
        "/assets/old.css",
        nil,
        "body {}",
        "text/css",
        {}
      )
    asset_updates = [
      Klenod::Build::AssetUpdate.new("/assets/new.css", nil, new_asset),
      Klenod::Build::AssetUpdate.new("/assets/old.css", old_asset, nil)
    ]
    result =
      Klenod::Build::InvalidationResult.new(
        [],
        [],
        [],
        [],
        ["/assets/new.css"],
        [],
        ["/assets/old.css"],
        asset_updates,
        []
      )
    event = Klenod::Dev::UpdateEvent.new(["a.rb"], ["b.rb"], 1, result)

    assert_equal(["a.rb"], event.changed_paths)
    assert_equal(["b.rb"], event.removed_paths)
    assert_equal(1, event.graph_version)
    assert_same(result, event.result)
    assert_equal(["/assets/new.css"], event.asset_changes.added)
    assert_equal(["/assets/old.css"], event.asset_changes.removed)
    assert_equal(asset_updates, event.asset_updates)
  end
end
