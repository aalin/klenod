# frozen_string_literal: true

require_relative "../__test__/support"

class Klenod::LSP::Languages::Ruby::Test < Minitest::Test
  include Klenod::LSP::TestSupport

  def setup
    @workspace = fixture_workspace
    @language = Klenod::LSP::Languages::Ruby.new
    @entry_id = module_id("entry.rb")
    @entry_source = fixture_source("entry.rb")
  end

  def test_valid_module_has_no_diagnostics
    assert_empty(diagnostics(@entry_source))
  end

  def test_ruby_syntax_error_is_reported
    diagnostic = diagnostics(@entry_source.sub("Default = Page", "Default = = Page")).fetch(0)

    assert_equal(6, diagnostic.range.start.line)
    assert_includes(diagnostic.message, "Ruby parse error")
  end

  def test_unresolved_import_is_reported_with_a_suggestion
    source = @entry_source.sub("pages/layout", "pages/layuot")

    diagnostic = diagnostics(source).fetch(0)

    assert_equal(3, diagnostic.range.start.line)
    assert_equal("pages/layuot", source.lines[3][diagnostic.range.start.character...diagnostic.range.end.character])
    assert_includes(diagnostic.message, "Did you mean \"pages/layout.rb\"?")
  end

  def test_unused_bindings_are_warned_about
    source = @entry_source.sub("EXTRAS = [Layout, Details].freeze\n", "")

    diagnostics = diagnostics(source)

    assert_equal(["Layout is imported but never used", "Details is imported but never used"], diagnostics.map(&:message))
    assert_equal([2, 2], diagnostics.map(&:severity))
    assert_equal([[1]] * 2, diagnostics.map(&:tags))
    assert_equal([3, 4], diagnostics.map { |diagnostic| diagnostic.range.start.line })
  end

  def test_definition_and_hover_on_import_literals
    line = @entry_source.lines[4]
    position = position(4, line.index("/components") + 2)

    location = @language.definition(analysis(@entry_source), position, @workspace)
    hover = @language.hover(analysis(@entry_source), position, @workspace)

    assert_equal(fixture_uri("components/Details.haml"), location.uri)
    assert_includes(hover.contents.value, "**/components/Details.haml** · `app:/components/Details.haml`")
    assert_includes(hover.contents.value, "Props: `children`, `summary`")
    assert_nil(@language.definition(analysis(@entry_source), position(0, 0), @workspace))
  end

  def test_document_links_cover_every_import
    links = @language.document_links(analysis(@entry_source), @workspace)

    assert_equal([2, 3, 4], links.map { |link| link.range.start.line })
    assert_equal(fixture_uri("pages/layout.rb"), links.fetch(1).target)
  end

  def test_code_actions_fix_unresolved_imports
    source = @entry_source.sub("pages/layout", "pages/layuot")

    actions = @language.code_actions(analysis(source), 3..3, @workspace)

    assert_equal(["Replace with \"pages/layout.rb\""], actions.map(&:title))
  end

  def test_references_to_a_ruby_module_from_ruby_and_haml_importers
    index = fixture_index(@workspace, @entry_id, module_id("pages/Page.haml"))
    line = @entry_source.lines[3]

    locations = @language.references(analysis(@entry_source), position(3, line.index("pages/layout") + 2), @workspace, index)

    assert_equal([[fixture_uri("entry.rb"), 3], [fixture_uri("pages/Page.haml"), 2], [fixture_uri("pages/Page.haml"), 4]], locations.map { |location| [location.uri, location.range.start.line] })
  end

  def test_rename_changes_the_binding_and_whole_word_uses
    edit = @language.rename(analysis(@entry_source), position(2, 1), "Home", @workspace)
    edits = edit.changes.fetch(fixture_uri("entry.rb"))

    assert_equal([[2, 0], [6, 10]], edits.map { |text_edit| [text_edit.range.start.line, text_edit.range.start.character] })
    assert_nil(@language.rename(analysis(@entry_source), position(0, 0), "Home", @workspace))
  end

  def test_completion_inside_import_literals
    source = @entry_source.sub("import(\"pages/layout\")", "import(\"pages/")

    list = @language.completion(analysis(source), position(3, 23), @workspace)

    assert_equal(["BrokenIntl.haml", "BrokenIntl.intl.en.toml", "LazyPage.haml", "Page.haml", "layout.rb", "lazy.rb", "page_spec.rb"], list.items.map(&:label))
    assert_nil(@language.completion(analysis(source), position(0, 0), @workspace))
  end

  private

  def analysis(source)
    @workspace.analyze(@entry_id, source)
  end

  def diagnostics(source)
    @language.diagnostics(analysis(source))
  end
end
