# frozen_string_literal: true

require_relative "../__test__/support"

class Klenod::LSP::Languages::CSS::Test < Minitest::Test
  include Klenod::LSP::TestSupport

  def setup
    @workspace = fixture_workspace
    @language = Klenod::LSP::Languages::CSS.new
    @home_id = module_id("styles/home.css")
    @home_source = fixture_source("styles/home.css")
  end

  def test_syntax_finds_imports_urls_and_composes_once_each
    literals = []
    Klenod::LSP::Languages::Syntax::CSS.each_literal("@import url(\"./a.css\"); .x { background: url(b.png) } .y { composes: c from \"./c.css\" }", 0) { |literal| literals << [literal.specifier, literal.kind] }

    assert_equal([["./a.css", :css_import], ["b.png", :asset_url], ["./c.css", :css_compose]], literals)
    assert_empty([].tap { |found| Klenod::LSP::Languages::Syntax::CSS.each_literal("a { background: url(data:image/png;base64,AAAA) }", 0) { |literal| found << literal } })
  end

  def test_valid_stylesheet_has_no_diagnostics
    assert_empty(diagnostics(@home_source))
  end

  def test_unresolved_import_is_reported_on_the_literal
    source = @home_source.sub("@import \"./base.css\"", "@import \"./bsae.css\"")

    diagnostic = diagnostics(source).fetch(0)

    assert_equal(0, diagnostic.range.start.line)
    assert_equal("./bsae.css", source.lines[0][diagnostic.range.start.character...diagnostic.range.end.character])
    assert_includes(diagnostic.message, "Did you mean")
  end

  def test_definition_hover_and_links_follow_imports_urls_and_composes
    analysis = analysis(@home_source)

    assert_equal(fixture_uri("styles/base.css"), @language.definition(analysis, position(0, 12), @workspace).uri)
    assert_equal(fixture_uri("styles/base.css"), @language.definition(analysis, position(3, 26), @workspace).uri)
    assert_equal(fixture_uri("pattern.svg"), @language.definition(analysis, position(4, 22), @workspace).uri)
    assert_includes(@language.hover(analysis, position(0, 12), @workspace).contents.value, "`app:/styles/base.css`")
    assert_equal([0, 3, 4], @language.document_links(analysis, @workspace).map { |link| link.range.start.line })
    assert_nil(@language.definition(analysis, position(2, 2), @workspace))
  end

  def test_completion_inside_import_and_url
    source = @home_source.sub("@import \"./base.css\"", "@import \"./")

    list = @language.completion(analysis(source), position(0, 11), @workspace)

    assert_equal(["base.css", "home.css"], list.items.map(&:label))
    assert_equal(["pages/", "pattern.svg"], @language.completion(analysis(@home_source.sub("url(\"../pattern.svg\")", "url(\"../pat")), position(4, 24), @workspace).items.map(&:label))
  end

  def test_references_and_rename_on_move_treat_stylesheets_as_importers
    index = fixture_index(@workspace, @home_id)

    locations = @language.references(@workspace.analyze(module_id("styles/base.css"), fixture_source("styles/base.css")), position(0, 0), @workspace, index)
    assert_equal([[0, 9], [3, 23]], locations.map { |location| [location.range.start.line, location.range.start.character] })
    assert(locations.all? { |location| location.uri == fixture_uri("styles/home.css") })

    edit = Klenod::LSP::Renames.call([[fixture_uri("styles/base.css"), fixture_uri("styles/shared/base.css")]], index, @workspace)
    assert_equal(["./shared/base.css", "./shared/base.css"], edit.changes.fetch(fixture_uri("styles/home.css")).map(&:new_text))
  end

  private

  def analysis(source)
    @workspace.analyze(@home_id, source)
  end

  def diagnostics(source)
    @language.diagnostics(analysis(source))
  end
end
