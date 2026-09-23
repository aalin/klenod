# frozen_string_literal: true

require_relative "test_support"

class Klenod::Build::Plugins::HamlPlugin::ParserTest < Klenod::Build::Plugins::HamlPlugin::TestSupport
  def test_parse_haml_adds_static_class_metadata_to_tag_nodes
    root =
      Klenod::Build::Plugins::HamlPlugin.parse_haml(
        <<~HAML
          %figure.card(class="featured")
            %img.image
        HAML
      )

    figure = root.children.fetch(0)
    image = figure.children.fetch(0)

    assert_equal({shorthand: ["card"], literal: ["featured"]}, figure.value.fetch(:klenod_class_metadata))
    assert_equal({shorthand: ["image"], literal: []}, image.value.fetch(:klenod_class_metadata))
  end

  def test_parse_haml_supports_member_expressions_in_parenthesized_attributes
    tag =
      Klenod::Build::Plugins::HamlPlugin.parse_haml(
        "%YouTubeVideo[key](video_id=video.id title=video.title)\n"
      ).children.fetch(0)

    assert_equal({}, tag.value.fetch(:attributes))
    assert_equal("{\"video_id\" => video.id,\"title\" => video.title,}", tag.value.fetch(:dynamic_attributes).new)
    assert_equal("[key]", tag.value.fetch(:object_ref))
  end

  def test_parse_haml_supports_index_expressions_in_parenthesized_attributes
    tag = Klenod::Build::Plugins::HamlPlugin.parse_haml("%a(href=link[:href])\n").children.fetch(0)

    assert_equal("{\"href\" => link[:href],}", tag.value.fetch(:dynamic_attributes).new)
  end

  def test_parse_haml_preserves_boolean_attributes_with_extended_parenthesized_attributes
    tag =
      Klenod::Build::Plugins::HamlPlugin.parse_haml(
        "%Input(name=\"password\" type=\"password\" label=\"Password (8+ characters)\" required pattern=\".{8,}\" autocomplete=\"off\")\n"
      ).children.fetch(0)

    assert_equal(
      "{\"name\" => \"password\",\"type\" => \"password\",\"label\" => \"Password (8+ characters)\",\"required\" => true,\"pattern\" => \".{8,}\",\"autocomplete\" => \"off\",}",
      tag.value.fetch(:dynamic_attributes).new
    )
  end

  def test_parse_haml_supports_a_trailing_boolean_attribute_with_an_extended_parenthesized_attribute
    tag = Klenod::Build::Plugins::HamlPlugin.parse_haml("%Input(pattern=value.match required)\n").children.fetch(0)

    assert_equal("{\"pattern\" => value.match,\"required\" => true,}", tag.value.fetch(:dynamic_attributes).new)
  end

  def test_parse_haml_supports_consecutive_boolean_attributes_with_an_extended_parenthesized_attribute
    tag = Klenod::Build::Plugins::HamlPlugin.parse_haml("%Input(title=user.name disabled required)\n").children.fetch(0)

    assert_equal(
      "{\"title\" => user.name,\"disabled\" => true,\"required\" => true,}",
      tag.value.fetch(:dynamic_attributes).new
    )
  end

  def test_parse_haml_supports_compound_expressions_and_regex_values_in_parenthesized_attributes
    tag =
      Klenod::Build::Plugins::HamlPlugin.parse_haml(
        "%Input(title=(user.name ? user.name : fallback.name) pattern=/a b/ required)\n"
      ).children.fetch(0)

    assert_equal(
      "{\"title\" => (user.name ? user.name : fallback.name),\"pattern\" => /a b/,\"required\" => true,}",
      tag.value.fetch(:dynamic_attributes).new
    )
  end

  def test_parse_haml_supports_parenthesized_attributes_starting_on_the_next_line
    root =
      Klenod::Build::Plugins::HamlPlugin.parse_haml(
        <<~HAML
          %a(
            href="/foo"
            target="_blank"
          ) Foo
          %p After
        HAML
      )

    link, after = root.children

    assert_equal({"href" => "/foo", "target" => "_blank"}, link.value.fetch(:attributes))
    assert_equal("Foo", link.value.fetch(:value))
    assert_equal(1, link.line)
    assert_equal(5, after.line)
  end

  def test_parse_haml_reports_nesting_errors_after_multiline_parenthesized_attributes_on_the_nested_line
    error =
      assert_raises(Klenod::Build::Plugins::HamlPlugin::ParseError) do
        Klenod::Build::Plugins::HamlPlugin.parse_haml(
          <<~HAML
            %a(
              href="/foo"
            ) Foo
              %b Nested
          HAML
        )
      end

    assert_equal(4, error.line)
    assert_includes(error.message, "Illegal nesting")
  end

  def test_parse_haml_supports_member_expressions_in_multiline_parenthesized_attributes
    root =
      Klenod::Build::Plugins::HamlPlugin.parse_haml(
        <<~HAML
          %a(href=link.href
            title="Close (x)"
            data-id=link[:id]) Foo
          %p After
        HAML
      )

    link, after = root.children

    assert_equal(
      "{\"href\" => link.href,\"title\" => \"Close (x)\",\"data-id\" => link[:id],}",
      link.value.fetch(:dynamic_attributes).new
    )
    assert_equal("Foo", link.value.fetch(:value))
    assert_equal(1, link.line)
    assert_equal(4, after.line)
  end

  def test_parse_haml_ignores_parentheses_inside_quoted_parenthesized_attribute_values
    tag = Klenod::Build::Plugins::HamlPlugin.parse_haml("%a(title=\")\" href=link.href) Foo\n").children.fetch(0)

    assert_equal("{\"title\" => \")\",\"href\" => link.href,}", tag.value.fetch(:dynamic_attributes).new)
    assert_equal("Foo", tag.value.fetch(:value))
  end

  def test_parse_haml_rejects_ambiguous_unparenthesized_ternary_attributes
    error =
      assert_raises(Klenod::Build::Plugins::HamlPlugin::ParseError) do
        Klenod::Build::Plugins::HamlPlugin.parse_haml("%Input(title=condition ? a : b class=styles.field)\n")
      end

    assert_includes(error.message, "Invalid attribute list")
  end

  def test_parse_haml_wraps_haml_syntax_errors_with_source_context
    error =
      assert_raises(Klenod::Build::Plugins::HamlPlugin::ParseError) do
        Klenod::Build::Plugins::HamlPlugin.parse_haml(
          <<~HAML,
            %p Before
            %*
            %p After
          HAML
          module_id: ModuleId.new("pages/demo/page.haml", nil)
        )
      end

    assert_equal(ModuleId.new("pages/demo/page.haml", nil), error.module_id)
    assert_equal(2, error.line)
    assert_includes(error.message, "pages/demo/page.haml:2: Haml parse error")
    assert_includes(error.message, "Invalid tag")
    assert_includes(error.message, "> 2 | %*")
  end

  def test_haml_plugin_wraps_inline_css_parse_errors_with_source_context
    plugin = Klenod::Build::Plugins::HamlPlugin.new
    module_id = ModuleId.new("pages/page.haml", nil)
    source = <<~HAML
      %h1 Hello
      %time(datetime=post.fetch("date")= post.fetch("date")
    HAML
    error =
      assert_raises(Klenod::Build::Plugins::HamlPlugin::ParseError) do
        plugin.send(:inline_css_sources, source, module_id: module_id)
      end

    assert_equal(2, error.line)
    assert_includes(error.message, "pages/page.haml:2: Haml parse error")
    assert_includes(error.message, "> 2 | %time(datetime=post.fetch(\"date\")= post.fetch(\"date\")")
  end

  def test_inline_css_sources_include_haml_origin_offsets
    plugin = Klenod::Build::Plugins::HamlPlugin.new
    source = <<~HAML
      %h1 Hello
      :css
        .title { color: red; }
    HAML

    inline_source = plugin.send(:inline_css_sources, source, module_id: ModuleId.new("pages/page.haml", nil)).fetch(0)

    assert_equal(".title { color: red; }\n", inline_source.text)
    assert_equal(2, inline_source.line_offset)
    assert_equal(2, inline_source.column_offset)
  end
end
