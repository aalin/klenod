# frozen_string_literal: true

require_relative "../__test__/support"

class Klenod::LSP::Languages::Haml::Test < Minitest::Test
  include Klenod::LSP::TestSupport

  def setup
    @workspace = fixture_workspace
    @language = Klenod::LSP::Languages::Haml.new
    @page_id = module_id("pages/Page.haml")
    @page_source = fixture_source("pages/Page.haml")
  end

  def test_valid_page_has_no_diagnostics
    assert_empty(diagnostics(@page_source))
  end

  def test_haml_syntax_error_is_reported_on_its_line
    source = @page_source.sub("  %Details{", "      %Details{")

    diagnostic = diagnostics(source).fetch(0)

    assert_equal(5, diagnostic.range.start.line)
    assert_equal(0, diagnostic.range.start.character)
    assert_includes(diagnostic.message, "Haml parse error")
    assert_includes(diagnostic.message, "indented")
    assert_equal("klenod", diagnostic.source)
  end

  def test_ruby_parse_error_in_script_is_reported_on_its_line
    source = @page_source.sub("    %p Lorem ipsum", "    %p= greeting(")

    diagnostic = diagnostics(source).fetch(0)

    assert_equal(6, diagnostic.range.start.line)
    assert_match(/syntax error/i, diagnostic.message)
  end

  def test_generated_ruby_error_maps_back_to_the_ruby_filter_line
    source = @page_source.sub("  Layout = import(\"./layout\")", "  Layout = import(\"./layout\")\n  broken = = 1")

    diagnostics = diagnostics(source)

    refute_empty(diagnostics)
    assert(diagnostics.all? { |diagnostic| diagnostic.message.start_with?("Generated Ruby syntax error") })
    assert_equal(3, diagnostics.fetch(0).range.start.line)
  end

  def test_unresolved_import_is_reported_on_the_literal_with_a_suggestion
    source = @page_source.sub("/components/Details", "/components/Detials")

    diagnostic = diagnostics(source).fetch(0)

    assert_equal(1, diagnostic.range.start.line)
    assert_equal("/components/Detials", source.lines[1][diagnostic.range.start.character...diagnostic.range.end.character])
    assert_includes(diagnostic.message, "Could not resolve \"/components/Detials\"")
    assert_includes(diagnostic.message, "Did you mean \"/components/Details.haml\"?")
  end

  def test_dynamic_import_is_reported_at_the_top
    source = @page_source.sub("import(\"/components/Details\")", "import(name)")

    diagnostic = diagnostics(source).fetch(0)

    assert_equal(0, diagnostic.range.start.line)
    assert_includes(diagnostic.message, "DynamicImportError")
  end

  def test_definition_on_component_tag_returns_the_imported_file
    location = definition(@page_source, position(5, 4))

    assert_equal(fixture_uri("/components/Details.haml"), location.uri)
    assert_equal(0, location.range.start.line)
  end

  def test_definition_on_component_tag_accepts_the_cursor_at_the_end_of_the_name
    location = definition(@page_source, position(5, 10))

    assert_equal(fixture_uri("/components/Details.haml"), location.uri)
  end

  def test_definition_on_import_literal_returns_the_file
    line = @page_source.lines[2]

    location = definition(@page_source, position(2, line.index("./layout") + 3))

    assert_equal(fixture_uri("pages/layout.rb"), location.uri)
  end

  def test_definition_resolves_imports_missing_from_the_analysis
    source = @page_source.sub("import(\"/components/Details\")", "import(name)")
    line = source.lines[2]

    location = definition(source, position(2, line.index("./layout") + 3))

    assert_equal(fixture_uri("pages/layout.rb"), location.uri)
  end

  def test_definition_on_namespaced_component_uses_the_first_constant
    source = @page_source.sub("%Layout", "%Layout::Nested")

    location = definition(source, position(4, 9))

    assert_equal(fixture_uri("pages/layout.rb"), location.uri)
  end

  def test_definition_ignores_other_positions
    assert_nil(definition(@page_source, position(0, 0)))
    assert_nil(definition(@page_source, position(6, 6)))
    assert_nil(definition(@page_source, position(1, 4)))
    assert_nil(definition(@page_source, position(40, 0)))
  end

  def test_definition_ignores_glob_imports_and_unbound_constants
    source = @page_source.sub("import(\"./layout\")", "import_glob(\"./*.rb\")").sub("%Layout", "%Unknown")
    line = source.lines[2]

    assert_nil(definition(source, position(2, line.index("./*.rb") + 1)))
    assert_nil(definition(source, position(4, 3)))
  end

  private

  def diagnostics(source)
    @language.diagnostics(@workspace.analyze(@page_id, source))
  end

  def definition(source, position)
    @language.definition(@workspace.analyze(@page_id, source), position, @workspace)
  end
end
