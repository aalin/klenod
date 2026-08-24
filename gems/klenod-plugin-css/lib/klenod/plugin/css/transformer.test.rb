# frozen_string_literal: true

require "json"
require "minitest/autorun"

require "klenod/plugin/css"

class Klenod::Plugin::CSS::TransformerTest < Minitest::Test
  def test_transform_scopes_classes_and_tags_by_default
    result =
      Klenod::Plugin::CSS::Transformer.transform(
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
      Klenod::Plugin::CSS::Transformer.transform(
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

  def test_transform_accepts_custom_patterns
    result =
      Klenod::Plugin::CSS::Transformer.transform(
        "components/Card.css",
        ".title { color: red; }\nmain { display: block; }\n",
        minify: false,
        class_pattern: "c_[hash]_[local]",
        tag_pattern: "t_[local]_[hash]"
      )

    assert_match(/\Ac_[A-Za-z0-9_-]{8}_title\z/, result.classes.fetch(:title))
    assert_match(/\At_main_[A-Za-z0-9_-]{8}\z/, result.elements.fetch(:main))
  end

  def test_transform_reports_dependencies_and_source_map
    source = "@import \"./base.css\";\n.logo { background: url(\"./logo.png\"); }\n"

    result =
      Klenod::Plugin::CSS::Transformer.transform(
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
      Klenod::Plugin::CSS::Transformer.transform(
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
      [Klenod::Plugin::CSS::ComposeDependency[name: :typography, specifier: "./typography.css"]],
      heading.composes
    )
    assert_equal([Klenod::Plugin::CSS::ComposeLocal[name: :heading]], title.composes)
    assert_equal([Klenod::Plugin::CSS::ComposeGlobal[name: "utility"]], external.composes)
  end
end
