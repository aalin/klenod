# frozen_string_literal: true

require "minitest/autorun"

require_relative "dependency"
require_relative "errors"
require_relative "module_id"
require_relative "resolution_error_formatter"

class Klenod::Build::ResolutionErrorFormatter::Test < Minitest::Test
  Dependency = Klenod::Build::Dependency
  ModuleId = Klenod::Build::ModuleId
  ResolveError = Klenod::Build::ResolveError
  SourceLocation = Klenod::Build::SourceLocation

  def test_formats_an_incorrect_case_error
    error = resolution_error(:incorrect_case, suggestions: ["app:/components/DocsSection.haml"])

    assert_equal(
      <<~TEXT.chomp,
        Incorrect import path casing

          Import:      /components/Docssection.haml
          Imported by: routes/page.haml:2
          Source root: /app/src

          Use:
            - /components/DocsSection.haml
      TEXT
      Klenod::Build::ResolutionErrorFormatter.format(error, source_root: "/app/src")
    )
  end

  def test_formats_multiple_suggestions
    error = resolution_error(
      :not_found,
      requested: "../components/DocsSectio",
      suggestions: ["app:/components/DocsSection.haml", "app:/components/DocsSection.rb"]
    )

    assert_equal(["../components/DocsSection.haml", "../components/DocsSection.rb"], error.suggestions)
    assert_includes(
      Klenod::Build::ResolutionErrorFormatter.format(error),
      "  Did you mean?\n    - ../components/DocsSection.haml\n    - ../components/DocsSection.rb"
    )
  end

  def test_omits_the_suggestion_section_when_there_are_no_suggestions
    error = resolution_error(:not_found, suggestions: [])
    formatted = Klenod::Build::ResolutionErrorFormatter.format(error)

    refute_includes(formatted, "Did you mean?")
    refute_includes(formatted, "Use:")
  end

  def test_preserves_scheme_and_query_in_replacements
    dependency = dependency("app:/components/docssection.haml?raw=1")
    error = raw_error(:not_found, ["app:/components/DocsSection.haml"])
      .with_resolution_context(dependency: dependency, importer_id: dependency.importer_id)

    assert_equal(["app:/components/DocsSection.haml?raw=1"], error.suggestions)
  end

  def test_keeps_context_for_other_resolve_errors
    dependency = dependency("virtual:unsupported")
    error = ResolveError.new("Unsupported virtual import")
      .with_resolution_context(dependency: dependency, importer_id: dependency.importer_id)

    assert_includes(error.message, 'while resolving "virtual:unsupported"')
    assert_includes(error.message, "from app:/routes/page.haml")
  end

  def test_keeps_non_app_importer_schemes
    dependency = Dependency.create(
      specifier: "./Header",
      importer_id: ModuleId.new("gem://klenod-ui/components/Page.rb"),
      kind: :ruby_import,
      loc: SourceLocation.new("gem://klenod-ui/components/Page.rb", 4, 3)
    )
    error = raw_error(:not_found, [])
      .with_resolution_context(dependency: dependency, importer_id: dependency.importer_id)

    assert_equal("gem://klenod-ui/components/Page.rb:4", error.imported_by)
  end

  def test_formats_a_compact_ansi_error_heading
    error = resolution_error(:incorrect_case, suggestions: ["app:/components/DocsSection.haml"])
    formatted = Klenod::Build::ResolutionErrorFormatter.format(
      error,
      source_context: "Source:\n\e[1;31m> 2 | broken\e[0m\n  3 | valid",
      ansi: true
    )

    assert_match(/\A\e\[1;31;47m ERROR /, formatted)
    assert_includes(formatted, "Incorrect import path casing")
    assert_includes(formatted, "#{Klenod::Build::ResolutionErrorFormatter::ANSI_BACKGROUND}\n\n  Import:")
    assert_includes(formatted, "> 2 | broken#{Klenod::Build::ResolutionErrorFormatter::ANSI_BACKGROUND}")
    assert_match(/\e\[0m\z/, formatted)
    refute_includes(formatted, "Backtrace:")
  end

  private

  def resolution_error(reason, suggestions:, requested: "/components/Docssection.haml")
    dependency = dependency(requested)
    raw_error(reason, suggestions)
      .with_resolution_context(dependency: dependency, importer_id: dependency.importer_id)
  end

  def raw_error(reason, suggestions)
    ResolveError.new(
      nil,
      unresolved_path: "components/Docssection.haml",
      reason: reason,
      requested_specifier: "app:/components/Docssection.haml",
      suggestions: suggestions
    )
  end

  def dependency(specifier)
    Dependency.create(
      specifier: specifier,
      importer_id: ModuleId.new("app:/routes/page.haml"),
      kind: :haml_import,
      loc: SourceLocation.new("app:/routes/page.haml", 2, 17)
    )
  end
end
