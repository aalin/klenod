# frozen_string_literal: true

require_relative "../../__test__/support"

class Klenod::LSP::Languages::Haml::Classes::Test < Minitest::Test
  include Klenod::LSP::TestSupport

  def setup
    @workspace = fixture_workspace
    @index = fixture_index(@workspace, module_id("components/Details.haml"))
    @language = Klenod::LSP::Languages::Haml.new
    @details_id = module_id("components/Details.haml")
    @details_source = fixture_source("components/Details.haml")
  end

  def test_map_comes_from_the_companion_stylesheet
    map = Klenod::LSP::Languages::Haml::Classes.map(analysis(@details_source), @workspace, @index)

    assert_equal(%w[summary wrapper], map.keys.sort)
    assert_equal("app:/components/Details.css", map.fetch("wrapper").module_id.to_s)
    assert_match(/wrapper/, map.fetch("wrapper").generated)
    assert_nil(Klenod::LSP::Languages::Haml::Classes.map(@workspace.analyze(module_id("pages/Page.haml"), fixture_source("pages/Page.haml")), @workspace, @index), "no styles means plain classes")
  end

  def test_unknown_classes_warn_only_when_the_component_has_styles
    source = @details_source.sub("%details.wrapper", "%details.wrapper.missing").sub("ClassNames[:summary]", "ClassNames[:nope]")

    diagnostics = @language.diagnostics(analysis(source), @workspace, @index)

    assert_equal(["missing", "nope"], diagnostics.map { |diagnostic| diagnostic.message[/class "([^"]+)"/, 1] })
    assert_equal([2, 2], diagnostics.map(&:severity))
    assert_equal("missing", source.lines[0][diagnostics.fetch(0).range.start.character...diagnostics.fetch(0).range.end.character])
    assert_includes(diagnostics.fetch(0).message, "components/Details.css")
    assert_empty(@language.diagnostics(@workspace.analyze(module_id("pages/Page.haml"), "%section.unstyled\n"), @workspace, @index))
  end

  def test_definition_and_hover_on_shorthand_and_lookups
    analysis = analysis(@details_source)

    location = @language.definition(analysis, position(0, 12), @workspace, @index)
    assert_equal(fixture_uri("components/Details.css"), location.uri)
    assert_equal({line: 0, character: 0}, {line: location.range.start.line, character: location.range.start.character})

    location = @language.definition(analysis, position(1, 33), @workspace, @index)
    assert_equal(2, location.range.start.line)

    hover = @language.hover(analysis, position(0, 12), @workspace, @index)
    assert_includes(hover.contents.value, "**.wrapper** · `components/Details.css`")
    assert_includes(hover.contents.value, "Rendered as `")
    assert_nil(@language.definition(analysis, position(2, 4), @workspace, @index))
  end

  def test_inline_css_filters_define_classes_in_the_document
    source = <<~HAML
      :css
        .card { padding: 1rem; }

      %section.card.missing
    HAML
    analysis = @workspace.analyze(module_id("pages/Card.haml"), source)

    diagnostics = @language.diagnostics(analysis, @workspace, @index)
    assert_equal(["missing"], diagnostics.map { |diagnostic| diagnostic.message[/class "([^"]+)"/, 1] })
    assert_includes(diagnostics.fetch(0).message, "inline :css")

    location = @language.definition(analysis, position(3, 11), @workspace, @index)
    assert_equal(fixture_uri("pages/Card.haml"), location.uri)
    assert_equal({line: 1, character: 2}, {line: location.range.start.line, character: location.range.start.character})
  end

  def test_completion_offers_stylesheet_classes
    analysis = analysis(@details_source.sub("%details.wrapper", "%details.w"))

    list = @language.completion(analysis, position(0, 10), @workspace, @index)
    assert_equal(["wrapper"], list.items.map(&:label))
    assert_equal({line: 0, character: 9}, {line: list.items.fetch(0).text_edit.range.start.line, character: list.items.fetch(0).text_edit.range.start.character})

    lookup = @language.completion(analysis(@details_source.sub("ClassNames[:summary]", "ClassNames[:s")), position(1, 32), @workspace, @index)
    assert_equal(["summary"], lookup.items.map(&:label))
    assert_empty(@language.completion(@workspace.analyze(module_id("pages/Page.haml"), "%section.un\n"), position(0, 11), @workspace, @index).items)
  end

  private

  def analysis(source)
    @workspace.analyze(@details_id, source)
  end
end
