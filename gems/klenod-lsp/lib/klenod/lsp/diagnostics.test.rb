# frozen_string_literal: true

require_relative "__test__/support"

class Klenod::LSP::Diagnostics::Test < Minitest::Test
  include Klenod::LSP::TestSupport

  def test_companion_parse_error_names_the_companion_on_the_first_line
    workspace = fixture_workspace
    analysis = workspace.analyze(module_id("pages/BrokenIntl.haml"), fixture_source("pages/BrokenIntl.haml"))

    diagnostic = Klenod::LSP::Diagnostics.for_analysis(analysis).fetch(0)

    assert_equal(0, diagnostic.range.start.line)
    assert_includes(diagnostic.message, "pages/BrokenIntl.intl.en.toml")
    assert_includes(diagnostic.message, "parse error")
  end

  def test_unmapped_generated_ruby_errors_fall_back_to_the_first_line_and_dedupe
    analysis =
      Klenod::LSP::Analysis.new(
        module_id: module_id("pages/Page.haml"),
        source: "%h1 Hello\n%p World\n",
        transform: nil,
        resolved_dependencies: [],
        build_error: nil,
        ruby_errors: [
          Klenod::LSP::RubyError.new(message: "unexpected end", generated_line: 12),
          Klenod::LSP::RubyError.new(message: "unexpected end", generated_line: 13)
        ],
        resolve_errors: []
      )

    diagnostics = Klenod::LSP::Diagnostics.for_analysis(analysis)

    assert_equal(1, diagnostics.length)
    assert_equal(0, diagnostics.fetch(0).range.start.line)
    assert_equal(9, diagnostics.fetch(0).range.end.character)
    assert_equal("Generated Ruby syntax error: unexpected end", diagnostics.fetch(0).message)
  end

  def test_source_error_without_a_line_uses_the_first_line
    analysis =
      Klenod::LSP::Analysis.new(
        module_id: module_id("pages/Page.haml"),
        source: "",
        transform: nil,
        resolved_dependencies: [],
        build_error: Klenod::Build::UnsupportedFileError.new("No plugin transformed \"pages/Page.haml\""),
        ruby_errors: [],
        resolve_errors: []
      )

    diagnostic = Klenod::LSP::Diagnostics.for_analysis(analysis).fetch(0)

    assert_equal(0, diagnostic.range.start.line)
    assert_equal(0, diagnostic.range.end.character)
    assert_equal("UnsupportedFileError: No plugin transformed \"pages/Page.haml\"", diagnostic.message)
  end

  def test_resolve_error_without_a_literal_in_the_source_uses_its_location_line
    dependency =
      Klenod::Build::Dependency.create(
        specifier: "missing",
        importer_id: module_id("pages/Page.haml"),
        kind: :haml_import,
        loc: Klenod::Build::SourceLocation.new("app:/pages/Page.haml", 2, 1)
      )
    error =
      Klenod::Build::ResolveError
        .new(nil, reason: :not_found, requested_specifier: "missing")
        .with_resolution_context(dependency: dependency, importer_id: dependency.importer_id)
    analysis =
      Klenod::LSP::Analysis.new(
        module_id: dependency.importer_id,
        source: "%h1 Hello\n%p World\n",
        transform: nil,
        resolved_dependencies: [],
        build_error: nil,
        ruby_errors: [],
        resolve_errors: [error]
      )

    diagnostic = Klenod::LSP::Diagnostics.for_analysis(analysis).fetch(0)

    assert_equal(1, diagnostic.range.start.line)
    assert_equal("Could not resolve \"missing\"", diagnostic.message)
  end
end
