# frozen_string_literal: true

require "json"
require "minitest/autorun"

require "klenod/plugin/css"

class Klenod::Build::Plugins::CSSPlugin::TransformerTest < Minitest::Test
  def test_transform_scopes_classes_and_tags_by_default
    result =
      Klenod::Build::Plugins::CSSPlugin::Transformer.transform(
        "components/Card.css",
        ".title { color: red; }\nimg { display: block; }\n",
        minify: false
      )

    assert_match(/components\/Card\.title\?/, result.classes.fetch(:title))
    assert_match(/components\/Card_img\?/, result.elements.fetch(:img))
    assert_includes(result.code, result.classes.fetch(:title).gsub("/", "\\/").gsub(".", "\\.").gsub("?", "\\?"))
    refute_includes(result.code, ".title {")
  end

  def test_transform_can_keep_original_class_and_tag_selectors
    result =
      Klenod::Build::Plugins::CSSPlugin::Transformer.transform(
        "components/Card.css",
        ".title { color: red; }\nimg { display: block; }\n",
        minify: false,
        transform_names: false
      )

    assert_match(/components\/Card\.title\?/, result.classes.fetch(:title))
    assert_match(/components\/Card_img\?/, result.elements.fetch(:img))
    assert_includes(result.code, ".title")
    assert_includes(result.code, "img")
  end

  def test_transform_scopes_classes_and_tags_inside_nested_selectors
    result =
      Klenod::Build::Plugins::CSSPlugin::Transformer.transform(
        "components/Card.css",
        <<~CSS,
          :is(h1, .title) { order: 1; }
          :where(.lead) { order: 2; }
          p:not(.kicker) { order: 3; }
          .card:has(> .image) { order: 4; }
          :-webkit-any(.legacy) { order: 5; }
          :nth-child(2 of .item) { order: 6; }
          :host(.dark) { order: 7; }
          ::slotted(.slot) { order: 8; }
          :local(.local) { order: 9; }
          :global(.global) .inner { order: 10; }
          ::cue(.vtt) { order: 11; }
        CSS
        class_pattern: "c_[local]",
        tag_pattern: "t_[local]"
      )

    assert_equal(
      [
        ":is(.t_h1,.c_title){order:1}",
        ":where(.c_lead){order:2}",
        ".t_p:not(.c_kicker){order:3}",
        ".c_card:has(>.c_image){order:4}",
        ":-webkit-any(.c_legacy){order:5}",
        ":nth-child(2 of .c_item){order:6}",
        ":host(.c_dark){order:7}",
        "::slotted(.c_slot){order:8}",
        ".c_local{order:9}",
        ".global .c_inner{order:10}",
        "::cue(.vtt){order:11}"
      ].join,
      result.code
    )
    assert_equal(
      %i[card dark image inner item kicker lead legacy local slot title],
      result.classes.keys.sort
    )
    assert_equal(%i[h1 p], result.elements.keys.sort)
  end

  def test_transform_accepts_custom_patterns
    result =
      Klenod::Build::Plugins::CSSPlugin::Transformer.transform(
        "components/Card.css",
        ":root { --gap: 1rem; }\n.title { color: red; }\nmain { display: block; }\n",
        minify: false,
        class_pattern: "c_[hash]_[local]",
        tag_pattern: "t_[local]_[hash]",
        local_css_variables: true,
        variable_pattern: "v_[hash]_[local]"
      )

    assert_match(/\Ac_[A-Za-z0-9_-]{8}_title\z/, result.classes.fetch(:title))
    assert_match(/\At_main_[A-Za-z0-9_-]{8}\z/, result.elements.fetch(:main))
    assert_match(/\A--v_[A-Za-z0-9_-]{8}_gap\z/, result.variables.fetch("--gap"))
  end

  def test_transform_reports_dependencies_and_source_map
    source = "@import \"./base.css\";\n.logo { background: url(\"./logo.png\"); }\n"

    result =
      Klenod::Build::Plugins::CSSPlugin::Transformer.transform(
        "styles/home.css",
        source,
        minify: false,
        transform_names: false
      )
    source_map = JSON.parse(result.source_map)

    assert_equal(["./base.css", "./logo.png"], result.dependencies.map(&:url))
    assert_equal(["styles/home.css"], source_map.fetch("sources"))
    assert_equal([source], source_map.fetch("sourcesContent"))
  end

  def test_transform_reports_local_global_and_dependency_compositions
    result =
      Klenod::Build::Plugins::CSSPlugin::Transformer.transform(
        "styles/heading.css",
        <<~CSS,
          .heading { composes: typography from "./typography.css"; }
          .title { composes: heading; }
          .external { composes: utility from global; }
        CSS
        minify: false
      )

    heading = result.exports.fetch(result.classes.fetch(:heading))
    title = result.exports.fetch(result.classes.fetch(:title))
    external = result.exports.fetch(result.classes.fetch(:external))

    assert_equal(
      [Klenod::Build::Plugins::CSSPlugin::ComposeDependency[name: :typography, specifier: "./typography.css"]],
      heading.composes
    )
    assert_equal([Klenod::Build::Plugins::CSSPlugin::ComposeLocal[name: :heading]], title.composes)
    assert_equal([Klenod::Build::Plugins::CSSPlugin::ComposeGlobal[name: "utility"]], external.composes)
  end

  def test_transform_can_localize_css_variables_and_report_dependencies
    result =
      Klenod::Build::Plugins::CSSPlugin::Transformer.transform(
        "styles/button.css",
        <<~CSS,
          :root { --accent-color: red; }
          .button {
            background: var(--accent-color);
            border-color: var(--border-color from "./vars.css");
            color: var(--text-color from global);
          }
        CSS
        minify: false,
        local_css_variables: true
      )

    variable = result.variables.fetch("--accent-color")

    assert_match(/\A--styles\/button-accent-color\?/, variable)
    assert_includes(result.code, variable.gsub("/", "\\/").gsub("?", "\\?"))
    assert_includes(result.code, "var(--text-color)")
    assert_equal(
      Klenod::Build::Plugins::CSSPlugin::VariableDependency[
        name: "--border-color",
        specifier: "./vars.css"
      ],
      result.references.values.fetch(0)
    )
  end

  def test_transform_keeps_css_variables_global_by_default
    result =
      Klenod::Build::Plugins::CSSPlugin::Transformer.transform(
        "styles/button.css",
        ":root { --accent-color: red; } .button { color: var(--accent-color); }",
        minify: false
      )

    assert_empty(result.variables)
    assert_includes(result.code, "--accent-color")
    assert_empty(result.references)
  end
end
