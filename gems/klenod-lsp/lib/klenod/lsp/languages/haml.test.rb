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

  def test_unused_bindings_are_warned_about_but_tag_and_ruby_uses_count
    source = @page_source.sub("%Layout\n", "%section\n")

    diagnostics = diagnostics(source)

    assert_equal(["Layout is imported but never used"], diagnostics.map(&:message))
    assert_equal(2, diagnostics.fetch(0).range.start.line)
    assert_empty(diagnostics(@page_source.sub("%Layout\n", "- helper = Layout\n")))
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

  def test_ruby_parse_error_in_a_filter_is_reported_on_the_haml_line
    source = @page_source.sub("  Layout = import(\"./layout\")", "  Layout = import(\"./layout\")\n  broken = = 1")

    diagnostics = diagnostics(source)

    refute_empty(diagnostics)
    assert(diagnostics.all? { |diagnostic| diagnostic.message.start_with?("Haml parse error") })
    assert_includes(diagnostics.fetch(0).message, "Could not parse Ruby filter")
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

  def test_half_typed_import_is_reported_instead_of_crashing
    source = @page_source.sub("import(\"./layout\")", "import(\"./la")

    diagnostic = diagnostics(source).fetch(0)

    assert_includes([2, 3], diagnostic.range.start.line, "the literal line or the end of the :ruby filter, where the parser gives up")
    assert_includes(diagnostic.message, "Haml parse error")
    assert_includes(diagnostic.message, "unterminated string")
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
    assert_nil(definition(@page_source, position(40, 0)))
  end

  def test_definition_ignores_glob_imports_and_unbound_constants
    source = @page_source.sub("import(\"./layout\")", "import_glob(\"./*.rb\")").sub("%Layout", "%Unknown")
    line = source.lines[2]

    assert_nil(definition(source, position(2, line.index("./*.rb") + 1)))
    assert_nil(definition(source, position(4, 3)))
  end

  def test_document_links_cover_resolvable_import_literals
    links = @language.document_links(@workspace.analyze(@page_id, @page_source), @workspace)

    assert_equal([fixture_uri("components/Details.haml"), fixture_uri("pages/layout.rb")], links.map(&:target))
    assert_equal(1, links.fetch(0).range.start.line)
    assert_equal("/components/Details", @page_source.lines[1][links.fetch(0).range.start.character...links.fetch(0).range.end.character])
  end

  def test_document_links_skip_unresolved_and_glob_imports
    source = @page_source.sub("/components/Details", "/components/Detials").sub("import(\"./layout\")", "import_glob(\"./*.rb\")")

    assert_empty(@language.document_links(@workspace.analyze(@page_id, source), @workspace))
  end

  def test_code_actions_offer_the_build_suggestions_for_unresolved_imports
    source = @page_source.sub("/components/Details", "/components/Detials")

    actions = @language.code_actions(@workspace.analyze(@page_id, source), 0..2, @workspace)

    assert_equal(["Replace with \"/components/Details.haml\""], actions.map(&:title))
    assert_equal("quickfix", actions.fetch(0).kind)
    assert_equal(true, actions.fetch(0).is_preferred)
    assert_includes(actions.fetch(0).diagnostics.fetch(0).message, "Did you mean")
    edit = actions.fetch(0).edit.changes.fetch(fixture_uri("pages/Page.haml")).fetch(0)
    assert_equal("/components/Details.haml", edit.new_text)
    assert_equal("/components/Detials", source.lines[1][edit.range.start.character...edit.range.end.character])
  end

  def test_code_actions_are_limited_to_the_requested_lines
    source = @page_source.sub("/components/Details", "/components/Detials")

    assert_empty(@language.code_actions(@workspace.analyze(@page_id, source), 4..6, @workspace))
    assert_empty(@language.code_actions(@workspace.analyze(@page_id, @page_source), 0..9, @workspace))
  end

  def test_references_list_import_literals_and_component_tags_across_the_index
    index = fixture_index(@workspace, module_id("entry.rb"), @page_id)

    locations = @language.references(@workspace.analyze(@page_id, @page_source), position(5, 4), @workspace, index, include_declaration: true)

    assert_equal(
      [
        [fixture_uri("components/Details.haml"), 0, 0],
        [fixture_uri("entry.rb"), 4, 18],
        [fixture_uri("pages/Page.haml"), 1, 20],
        [fixture_uri("pages/Page.haml"), 5, 3]
      ],
      locations.map { |location| [location.uri, location.range.start.line, location.range.start.character] }
    )
  end

  def test_references_without_a_target_use_the_document_itself
    index = fixture_index(@workspace, module_id("entry.rb"), module_id("pages/page_spec.rb"))

    locations = @language.references(@workspace.analyze(@page_id, @page_source), position(6, 6), @workspace, index)

    assert_equal([fixture_uri("entry.rb"), fixture_uri("pages/page_spec.rb")], locations.map(&:uri))
  end

  def test_code_lens_counts_references_to_the_document
    index = fixture_index(@workspace, module_id("entry.rb"), module_id("pages/page_spec.rb"))
    details = @workspace.analyze(module_id("components/Details.haml"), fixture_source("components/Details.haml"))
    index.ensure_collected(@page_id)

    page_lens = @language.code_lenses(@workspace.analyze(@page_id, @page_source), @workspace, index).fetch(0)
    details_lens = @language.code_lenses(details, @workspace, index).fetch(0)

    assert_equal("2 references", page_lens.command.title)
    assert_equal("editor.action.showReferences", page_lens.command.command)
    assert_equal(0, page_lens.range.start.line)
    assert_equal("3 references", details_lens.command.title, "import literals and %Details tags in Page plus the entry import")
    assert_equal("No references", @language.code_lenses(@workspace.analyze(module_id("pages/LazyPage.haml"), "%h1 Lazy\n"), @workspace, index).fetch(0).command.title)
  end

  def test_rename_changes_the_binding_tags_and_ruby_uses_but_not_text
    source = <<~HAML
      :ruby
        Details = import("/components/Details")
        Layout = import("./layout")
        helper = Details.new

      %Layout
        - widget = Details
        %Details{ summary: Details.name }
          %p Details are plain text
          %p= Details.name
        %Details::Nested(title=Details)
        %DetailsPanel
    HAML
    analysis = @workspace.analyze(@page_id, source)

    prepared = @language.prepare_rename(analysis, position(7, 5))
    assert_equal("Details", prepared[:placeholder])
    assert_equal({line: 7, character: 3}, {line: prepared[:range].start.line, character: prepared[:range].start.character})
    assert_nil(@language.prepare_rename(analysis, position(1, 25)), "import literals are not renamed")

    edit = @language.rename(analysis, position(7, 5), "Card", @workspace)
    edits = edit.changes.fetch(fixture_uri("pages/Page.haml"))

    assert_equal(
      [[1, 2], [3, 11], [6, 13], [7, 3], [7, 21], [9, 8], [10, 3], [10, 25]],
      edits.map { |text_edit| [text_edit.range.start.line, text_edit.range.start.character] }
    )
    assert(edits.all? { |text_edit| text_edit.new_text == "Card" })
    assert_raises(Klenod::LSP::Languages::ImportNavigation::InvalidRename) { @language.rename(analysis, position(7, 5), "card", @workspace) }
  end

  def test_definition_on_a_binding_constant_uses_its_import
    location = definition(@page_source, position(1, 4))

    assert_equal(fixture_uri("components/Details.haml"), location.uri)
  end

  def test_hover_on_component_tag_summarizes_the_component
    hover = hover(@page_source, position(5, 4))

    assert_equal("markdown", hover.contents.kind)
    assert_includes(hover.contents.value, "**Details** · `app:/components/Details.haml`")
    assert_includes(hover.contents.value, "`components/Details.haml`")
    assert_includes(hover.contents.value, "Props: `children`, `summary`")
    assert_includes(hover.contents.value, "Slots: `footer`")
    assert_equal(3, hover.range.start.character)
    assert_equal(10, hover.range.end.character)
  end

  def test_hover_on_import_literal_shows_the_module_without_props
    line = @page_source.lines[2]

    hover = hover(@page_source, position(2, line.index("./layout") + 3))

    assert_includes(hover.contents.value, "**./layout** · `app:/pages/layout.rb`")
    assert_includes(hover.contents.value, "`pages/layout.rb`")
    refute_includes(hover.contents.value, "Props")
  end

  def test_hover_omits_props_when_globals_are_not_mapped
    workspace = fixture_workspace(variables: nil)

    hover = @language.hover(workspace.analyze(@page_id, @page_source), position(5, 4), workspace)

    refute_includes(hover.contents.value, "Props")
  end

  def test_hover_ignores_other_positions
    assert_nil(hover(@page_source, position(0, 0)))
    assert_nil(hover(@page_source, position(6, 6)))
  end

  def test_completion_offers_bound_components_matching_the_partial_tag
    source = @page_source.sub("%Layout", "%De")

    list = completion(source, position(4, 3))

    assert_equal(false, list.is_incomplete)
    assert_equal(["Details"], list.items.map(&:label))
    assert_equal("app:/components/Details.haml", list.items.fetch(0).detail)
    assert_equal(1, list.items.fetch(0).text_edit.range.start.character)
    assert_equal(3, list.items.fetch(0).text_edit.range.end.character)
    assert_equal("Details", list.items.fetch(0).text_edit.new_text)
  end

  def test_completion_offers_every_binding_after_a_bare_percent
    source = @page_source.sub("%Layout", "%")

    list = completion(source, position(4, 1))

    assert_equal(%w[Details Layout], list.items.map(&:label).sort)
  end

  def test_completion_leaves_lowercase_tags_alone
    source = @page_source.sub("%Layout", "%di")

    assert_nil(completion(source, position(4, 3)))
    assert_nil(completion(source, position(6, 6)))
    assert_nil(completion(source, position(40, 0)))
  end

  def test_completion_lists_source_root_directories_for_absolute_paths
    source = @page_source.sub("import(\"/components/Details\")", "import(\"/comp")

    list = completion(source, position(1, 25))

    assert_equal(["components/"], list.items.map(&:label))
    assert_equal("components/", list.items.fetch(0).text_edit.new_text)
    assert_equal(21, list.items.fetch(0).text_edit.range.start.character)
    assert_equal(25, list.items.fetch(0).text_edit.range.end.character)
  end

  def test_completion_lists_directory_entries_without_tests_or_dotfiles
    source = @page_source.sub("import(\"/components/Details\")", "import(\"/components/")

    list = completion(source, position(1, 32))

    assert_equal(["Details.css", "Details.haml", "Details.intl.en.toml"], list.items.map(&:label))
    assert_equal("1Details.css", list.items.fetch(0).sort_text)
  end

  def test_completion_lists_entries_next_to_the_importer_for_relative_paths
    source = @page_source.sub("import(\"./layout\")", "import(\"./lay")

    list = completion(source, position(2, 24))

    assert_equal(["layout.rb"], list.items.map(&:label))
  end

  def test_completion_walks_up_to_the_source_root_but_not_beyond
    source = @page_source.sub("import(\"./layout\")", "import(\"../")

    list = completion(source, position(2, 22))

    assert_equal(["components/", "entry.rb", "pages/", "pattern.svg", "styles/"], list.items.map(&:label))
    assert_nil(completion(@page_source.sub("import(\"./layout\")", "import(\"../../"), position(2, 25)))
  end

  def test_completion_ignores_scheme_specifiers
    source = @page_source.sub("import(\"./layout\")", "import(\"gem://")

    assert_nil(completion(source, position(2, 25)))
  end

  private

  def diagnostics(source)
    @language.diagnostics(@workspace.analyze(@page_id, source))
  end

  def definition(source, position)
    @language.definition(@workspace.analyze(@page_id, source), position, @workspace)
  end

  def hover(source, position)
    @language.hover(@workspace.analyze(@page_id, source), position, @workspace)
  end

  def completion(source, position)
    @language.completion(@workspace.analyze(@page_id, source), position, @workspace)
  end
end
