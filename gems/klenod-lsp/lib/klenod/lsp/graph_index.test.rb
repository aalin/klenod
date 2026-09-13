# frozen_string_literal: true

require "fileutils"
require "logger"
require "stringio"
require "tmpdir"

require_relative "__test__/support"

class Klenod::LSP::GraphIndex::Test < Minitest::Test
  include Klenod::LSP::TestSupport

  class Progress
    attr_reader :events

    def initialize
      @events = []
    end

    def begin(total)
      @events << [:begin, total]
    end

    def report(done, total)
      @events << [:report, done, total]
    end

    def finish
      @events << [:finish]
    end
  end

  class SerialIndex < Klenod::LSP::GraphIndex
    attr_reader :maximum_active_collections

    def initialize(...)
      super
      @active_collections = 0
      @maximum_active_collections = 0
    end

    private

    def collect_root(...)
      @active_collections += 1
      @maximum_active_collections = [@maximum_active_collections, @active_collections].max
      sleep(0.001)
      super
    ensure
      @active_collections -= 1
    end
  end

  def test_start_collects_entrypoints_source_files_and_lazy_dependencies
    with_index(entrypoints: ["/entry.rb"]) do |index, _workspace|
      progress = Progress.new
      Sync do |task|
        index.start(task, progress: progress)
        index.wait
      end

      ids = index.records.keys.map(&:to_s)

      assert_includes(ids, "app:/entry.rb")
      assert_includes(ids, "app:/pages/Page.haml")
      assert_includes(ids, "app:/components/Details.haml")
      assert_includes(ids, "app:/pages/LazyPage.haml", "lazy imports are walked")
      assert_includes(ids, "app:/pages/page_spec.rb", "every source file is a root")
      assert_equal(["app:/pages/BrokenIntl.haml"], index.failed.keys)
      assert_equal([:begin], progress.events.first.first(1))
      assert_equal([:finish], progress.events.last)
      assert(index.records.values.flat_map(&:assets).all? { |asset| %i[css svg].include?(asset.metadata[:type]) }, "analysis mode emits no image, font, or JavaScript assets")
    end
  end

  def test_unresolved_entrypoints_are_reported_and_retried
    with_index(entrypoints: ["/missing"]) do |_index, workspace|
      logger_output = StringIO.new
      index = Klenod::LSP::GraphIndex.new(workspace: workspace, entrypoints: ["/missing"], logger: Logger.new(logger_output))
      Sync do |task|
        index.start(task)
        index.wait
        assert_includes(logger_output.string, "Entrypoint \"/missing\" did not resolve")

        File.write(File.join(workspace.source_dir, "missing.rb"), "Default = 1\n")
        affected = index.invalidate([File.join(workspace.source_dir, "missing.rb")], [])

        assert_includes(affected, "app:/missing.rb")
        assert(index.records.key?(Klenod::Build::ModuleId.new("app:/missing.rb")))
      end
    end
  end

  def test_start_serializes_with_on_demand_collection
    Dir.mktmpdir do |dir|
      FileUtils.cp_r("#{Klenod::LSP::TestSupport::FIXTURE_SOURCE_DIR}/.", dir)
      workspace = fixture_workspace(source_dir: dir)
      index = SerialIndex.new(workspace: workspace, logger: Logger.new(StringIO.new))

      Sync do |task|
        index.start(task)
        requested = task.async { index.ensure_collected(module_id("pages/Page.haml"), force: true) }
        index.wait
        requested.wait
      end

      assert_equal(1, index.maximum_active_collections)
    end
  end

  def test_dependents_and_invalidation_follow_file_changes
    with_index do |index, workspace|
      Sync do
        index.ensure_collected(module_id("pages/Page.haml"))

        assert_equal(["app:/pages/Page.haml"], index.dependents(module_id("pages/layout.rb")).map(&:to_s))

        File.delete(File.join(workspace.source_dir, "pages/layout.rb"))
        affected = index.invalidate([], [File.join(workspace.source_dir, "pages/layout.rb")])

        assert_includes(affected, "app:/pages/layout.rb")
        assert_includes(affected, "app:/pages/Page.haml")
        assert_includes(index.failed.keys, "app:/pages/Page.haml")

        File.write(File.join(workspace.source_dir, "pages/layout.rb"), "Default = 2\n")
        affected = index.invalidate([File.join(workspace.source_dir, "pages/layout.rb")], [])

        assert_includes(affected, "app:/pages/Page.haml")
        assert_empty(index.failed)
        assert_equal("Default = 2\n", index.record(module_id("pages/layout.rb")).source)
      end
    end
  end

  def test_forced_collection_follows_source_overrides_and_disk
    with_index do |index, workspace|
      id = module_id("pages/Page.haml")
      disk_source = File.read(File.join(workspace.source_dir, "pages/Page.haml"))
      buffer_source = disk_source.sub("/components/Details", "./LazyPage")

      Sync do
        index.ensure_collected(id)
        workspace.context.graph.override_source(id, buffer_source)
        index.ensure_collected(id, force: true)

        assert_equal(buffer_source, index.record(id).source)

        workspace.context.graph.clear_source_override(id)
        index.ensure_collected(id, force: true)

        assert_equal(disk_source, index.record(id).source)
      end
    end
  end

  private

  def with_index(entrypoints: [])
    Dir.mktmpdir do |dir|
      FileUtils.cp_r("#{Klenod::LSP::TestSupport::FIXTURE_SOURCE_DIR}/.", dir)
      workspace = fixture_workspace(source_dir: dir)
      index = Klenod::LSP::GraphIndex.new(workspace: workspace, entrypoints: entrypoints, logger: Logger.new(StringIO.new))

      yield index, workspace
    end
  end
end
