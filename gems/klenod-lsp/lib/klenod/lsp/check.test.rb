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
    assert_equal(["`LazyPage` is imported but never used"], diagnostics_for(results, "pages/lazy.rb").map(&:message))
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

      assert_equal(["Unknown prop `sumary` for `Details`; did you mean `summary`?"], results.first.diagnostics.map(&:message))
    end
  end

  def test_report_groups_sorted_diagnostics_by_file_aligned_across_files
    error = Klenod::LSP::Diagnostics.diagnostic(Klenod::LSP::Text::Span.new(11, 4, 8), "Broken\nhint")
    warning = Klenod::LSP::Diagnostics.warning(Klenod::LSP::Text::Span.new(0, 0, 3), "Unused")
    other = Klenod::LSP::Diagnostics.warning(Klenod::LSP::Text::Span.new(1, 2, 3), "Other")
    results = [
      Klenod::LSP::Check::Result.new(path: "/app/src/a.haml", diagnostics: [error, warning]),
      Klenod::LSP::Check::Result.new(path: "/app/src/b.rb", diagnostics: []),
      Klenod::LSP::Check::Result.new(path: "/app/src/c.rb", diagnostics: [other])
    ]
    output = StringIO.new

    count = Klenod::LSP::Check.report(results, output: output, root: "/app")

    assert_equal(3, count)
    assert_equal(<<~TEXT, output.string)
      src/a.haml
         1:1  warning  Unused
        12:5  error    Broken
                       hint

      src/c.rb
         2:3  warning  Other

      1 error, 2 warnings, 3 files checked.
    TEXT
  end

  def test_report_colors_paths_locations_severities_names_and_the_summary
    warning = Klenod::LSP::Diagnostics.warning(Klenod::LSP::Text::Span.new(0, 0, 3), "`Card` is unused\nsee `Other` and `x`")
    output = StringIO.new

    Klenod::LSP::Check.report([Klenod::LSP::Check::Result.new(path: "/app/a.haml", diagnostics: [warning])], output: output, root: "/app", color: true)

    assert_equal(<<~TEXT, output.string)
      \e[4ma.haml\e[0m
        \e[2m1:1\e[0m  \e[33mwarning\e[0m  \e[36mCard\e[0m is unused
                      \e[2msee \e[36mOther\e[0m\e[2m and \e[36mx\e[0m\e[2m\e[0m

      \e[33m1 warning\e[0m, 1 file checked.
    TEXT
  end

  def test_colors_only_terminals_without_no_color
    terminal = StringIO.new
    def terminal.tty? = true

    assert(Klenod::LSP::Check.color?(terminal, {}))
    refute(Klenod::LSP::Check.color?(terminal, {"NO_COLOR" => "1"}))
    refute(Klenod::LSP::Check.color?(StringIO.new, {}))
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
