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

  def test_definition_and_hover_on_import_literals
    line = @entry_source.lines[4]
    position = position(4, line.index("/components") + 2)

    location = @language.definition(analysis(@entry_source), position, @workspace)
    hover = @language.hover(analysis(@entry_source), position, @workspace)

    assert_equal(fixture_uri("components/Details.haml"), location.uri)
    assert_includes(hover.contents.value, "**/components/Details.haml** · `app:/components/Details.haml`")
    assert_includes(hover.contents.value, "Props: `$summary`")
    assert_nil(@language.definition(analysis(@entry_source), position(0, 0), @workspace))
  end

  def test_completion_inside_import_literals
    source = @entry_source.sub("import(\"pages/layout\")", "import(\"pages/")

    list = @language.completion(analysis(source), position(3, 23), @workspace)

    assert_equal(["BrokenIntl.haml", "BrokenIntl.intl.en.toml", "Page.haml", "layout.rb"], list.items.map(&:label))
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
