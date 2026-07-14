# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"

require_relative "../../../lib/klenod"
require_relative "update_logger"

class Example::UpdateLogger::Test < Minitest::Test
  FakeUpdate = Data.define(:errors, :asset_write_result) do
    def failed?
      !errors.empty?
    end

    def each_error(&)
      errors.each(&)
    end

    def asset_files_changed?
      asset_write_result && !asset_write_result.empty?
    end

    def written_asset_paths
      asset_write_result&.written_paths || []
    end

    def removed_asset_paths
      asset_write_result&.removed_paths || []
    end
  end

  def test_logs_successful_update_details
    Dir.mktmpdir do |dir|
      out = StringIO.new
      err = StringIO.new
      event =
        event(
          changed_paths: ["#{dir}/pages/page.haml"],
          result: result(
            reloaded: ["pages/page.haml"],
            reevaluated: ["pages/server.rb"],
            added_assets: ["/assets/new.css"],
            changed_assets: ["/assets/current.css"],
            removed_assets: ["/assets/old.css"]
          )
        )
      update =
        FakeUpdate.new(
          [],
          Klenod::Build::AssetWriteResult.new(["#{dir}/public/assets/new.css"], ["#{dir}/public/assets/old.css"])
        )

      logger(dir, out:, err:).log(event: event, update: update, duration: "12.0000ms")

      text = out.string
      assert_includes(text, "Update #4 completed")
      assert_includes(text, "(12.0000ms)")
      assert_includes(text, "changed files:")
      assert_includes(text, "pages/page.haml")
      assert_includes(text, "reloaded:")
      assert_includes(text, "reevaluated:")
      assert_includes(text, "pages/server.rb")
      assert_includes(text, "+")
      assert_includes(text, "/assets/new.css")
      assert_includes(text, "~")
      assert_includes(text, "/assets/current.css")
      assert_includes(text, "-")
      assert_includes(text, "/assets/old.css")
      assert_includes(text, "asset files:")
      assert_empty(err.string)
    end
  end

  def test_logs_removed_trigger_files
    Dir.mktmpdir do |dir|
      out = StringIO.new
      event =
        event(
          removed_paths: ["#{dir}/pages/old.haml"],
          result: result(removed: ["pages/old.haml"])
        )

      logger(dir, out: out).log(event: event, update: FakeUpdate.new([], nil), duration: "1.0000ms")

      assert_includes(out.string, "removed files:")
      assert_includes(out.string, "removed modules:")
      assert_includes(out.string, "pages/old.haml")
    end
  end

  def test_logs_when_changed_file_does_not_affect_loaded_graph
    Dir.mktmpdir do |dir|
      out = StringIO.new
      event =
        event(
          changed_paths: ["#{dir}/components/Figure.css"],
          result: result
        )

      logger(dir, out: out, env: {"NO_COLOR" => "1"}).log(event: event, update: FakeUpdate.new([], nil), duration: "1.0000ms")

      assert_includes(out.string, "changed files:")
      assert_includes(out.string, "components/Figure.css")
      assert_includes(out.string, "modules: no loaded graph modules affected")
    end
  end

  def test_logs_failed_update_to_error_output
    Dir.mktmpdir do |dir|
      out = StringIO.new
      err = StringIO.new
      error = StandardError.new("broken")
      event = event(changed_paths: ["#{dir}/pages/page.haml"], result: result(errors: [["pages/page.haml", error]]))
      update = FakeUpdate.new([["pages/page.haml", error]], nil)

      logger(dir, out:, err:).log(event: event, update: update, duration: "3.5000ms") do |module_id, update_error|
        "#{module_id}: #{update_error.message}\nSource:\n> 1 | %"
      end

      assert_empty(out.string)
      assert_includes(err.string, "Update #4 failed")
      assert_includes(err.string, "changed files:")
      assert_includes(err.string, "pages/page.haml")
      assert_includes(err.string, "  pages/page.haml: broken")
      assert_includes(err.string, "  Source:")
    end
  end

  def test_no_color_disables_ansi_codes
    Dir.mktmpdir do |dir|
      out = StringIO.new
      event = event(result: result(added_assets: ["/assets/new.css"]))

      logger(dir, out: out, env: {"NO_COLOR" => "1"}).log(event: event, update: FakeUpdate.new([], nil), duration: "1.0000ms")

      refute_match(/\e\[/, out.string)
      assert_includes(out.string, "+ /assets/new.css")
    end
  end

  private

  def logger(source_dir, out: StringIO.new, err: StringIO.new, env: {})
    Example::UpdateLogger.new(source_dir: source_dir, output: out, error_output: err, env: env)
  end

  def event(result:, changed_paths: [], removed_paths: [])
    Klenod::Dev::UpdateEvent.new(changed_paths, removed_paths, 4, result)
  end

  def result(reloaded: [], reevaluated: [], removed: [], added_assets: [], changed_assets: [], removed_assets: [], errors: [])
    Klenod::Build::InvalidationResult.new(
      [],
      removed,
      reloaded,
      reevaluated,
      added_assets,
      changed_assets,
      removed_assets,
      [],
      errors
    )
  end
end
