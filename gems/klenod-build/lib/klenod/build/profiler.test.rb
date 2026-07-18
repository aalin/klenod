# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"

require "klenod/build/context"
require "klenod/build/profiler"

class Klenod::Build::ProfilerTest < Minitest::Test
  def test_profiler_collects_totals
    profiler = Klenod::Build::Profiler.new(enabled: true)

    assert_equal("result", profiler.measure(:phase, plugin: "Plugin") { "result" })

    assert_equal([:phase], profiler.totals.keys)
    assert_operator(profiler.totals.fetch(:phase), :>=, 0.0)
    assert_equal([[:phase, "Plugin"]], profiler.totals_by_plugin.keys)
  end

  def test_profiler_can_record_totals_without_storing_events
    profiler = Klenod::Build::Profiler.new(enabled: true, store_events: false)

    profiler.measure(:phase, plugin: "Plugin") { nil }

    assert_empty(profiler.events)
    assert_equal([:phase], profiler.totals.keys)
    assert_equal([[:phase, "Plugin"]], profiler.totals_by_plugin.keys)
  end

  def test_context_records_plugin_timings_when_profiler_is_enabled
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "entry.rb"), <<~RUBY)
        Message = import("./message.txt")
      RUBY
      File.write(File.join(dir, "message.txt"), "Hello")

      profiler = Klenod::Build::Profiler.new(enabled: true)
      context = Klenod::Build::Context.new(source_dir: dir, profiler: profiler)

      context.build(entrypoints: ["entry"], output: File.join(dir, "dist", "bundle"))

      assert_includes(profiler.totals.keys, :entrypoints)
      assert_includes(profiler.totals.keys, :runtime_dependencies)
      assert(profiler.totals_by_plugin.keys.any? { |name, plugin| name == :plugin_transform && plugin.end_with?("TextPlugin") })
    end
  end

  def test_disabled_profiler_does_not_record_events
    profiler = Klenod::Build::Profiler.new

    profiler.measure(:phase) { nil }

    assert_empty(profiler.events)
  end
end
