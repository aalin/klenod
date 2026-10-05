# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require_relative "__test__/support"

class Klenod::LSP::Check::Test < Minitest::Test
  include Klenod::LSP::TestSupport

  def test_checks_every_source_file
    results = check

    assert_equal(
      %w[
        components/Details.css components/Details.haml entry.rb pages/BrokenIntl.haml pages/LazyPage.haml
        pages/Page.haml pages/layout.rb pages/lazy.rb pages/page_spec.rb styles/base.css styles/home.css
      ],
      results.map { |result| result.path.delete_prefix("#{FIXTURE_SOURCE_DIR}/") }
    )
    assert_empty(diagnostics_for(results, "pages/Page.haml"))
    assert_match(/Intl parse error/, diagnostics_for(results, "pages/BrokenIntl.haml").first.message)
    assert_equal(["LazyPage is imported but never used"], diagnostics_for(results, "pages/lazy.rb").map(&:message))
  end

  def test_checks_only_selected_files_and_directories
    results = check([fixture_path("pages/lazy.rb"), fixture_path("components")])

    assert_equal(
      [fixture_path("components/Details.css"), fixture_path("components/Details.haml"), fixture_path("pages/lazy.rb")],
      results.map(&:path)
    )
  end

  def test_reports_cross_file_diagnostics_from_the_collected_graph
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      FileUtils.cp_r("#{FIXTURE_SOURCE_DIR}/.", dir)
      page = File.join(dir, "pages/Page.haml")
      File.write(page, File.read(page).sub("summary:", "sumary:"))

      results = Klenod::LSP::Check.new(context: fixture_context(source_dir: dir)).call([page])

      assert_equal(["Unknown prop \"sumary\" for Details; did you mean \"summary\"?"], results.first.diagnostics.map(&:message))
    end
  end

  def test_report_prints_sorted_locations_relative_to_the_root_and_a_summary
    error = Klenod::LSP::Diagnostics.diagnostic(Klenod::LSP::Text::Span.new(2, 4, 8), "Broken\nhint")
    warning = Klenod::LSP::Diagnostics.warning(Klenod::LSP::Text::Span.new(0, 0, 3), "Unused")
    results = [
      Klenod::LSP::Check::Result.new(path: "/app/src/a.haml", diagnostics: [error, warning]),
      Klenod::LSP::Check::Result.new(path: "/app/src/b.rb", diagnostics: [])
    ]
    output = StringIO.new

    count = Klenod::LSP::Check.report(results, output: output, root: "/app")

    assert_equal(2, count)
    assert_equal(<<~TEXT, output.string)
      src/a.haml:1:1: warning: Unused
      src/a.haml:3:5: error: Broken
        hint
      1 error, 1 warning, 2 files checked.
    TEXT
  end

  def test_report_keeps_absolute_paths_outside_the_root_and_says_when_clean
    output = StringIO.new

    count = Klenod::LSP::Check.report([Klenod::LSP::Check::Result.new(path: "/other/a.rb", diagnostics: [])], output: output, root: "/app")

    assert_equal(0, count)
    assert_equal("No problems found, 1 file checked.\n", output.string)
    assert_equal("/other/a.rb", Klenod::LSP::Check.display_path("/other/a.rb", "/app"))
  end

  private

  def check(paths = [])
    Klenod::LSP::Check.new(context: fixture_context, logger: Logger.new(StringIO.new)).call(paths)
  end

  def diagnostics_for(results, relative)
    results.find { |result| result.path == fixture_path(relative) }.diagnostics
  end
end
