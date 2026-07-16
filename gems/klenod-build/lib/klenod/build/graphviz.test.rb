# frozen_string_literal: true

require "minitest/autorun"
require "uri"

require_relative "graphviz"

class Klenod::Build::Graphviz::Test < Minitest::Test
  def test_exports_colored_modules_import_edges_and_asset_edges
    bundle = sample_bundle

    dot = Klenod::Build::Graphviz.call(bundle)

    assert_includes(dot, "digraph klenod")
    assert_includes(dot, "label=\"entry.rb\\nrb entrypoint\"")
    assert_includes(dot, "label=\"components/Card.haml\\nhaml\"")
    assert_includes(dot, "label=\"virtual:router\\nvirtual\"")
    assert_includes(dot, "fillcolor=\"#d7ecff\"")
    assert_includes(dot, "fillcolor=\"#f4dcff\"")
    assert_includes(dot, "fillcolor=\"#eceff4\"")
    assert_includes(dot, "style=\"solid\"")
    assert_includes(dot, "style=\"dashed\"")
    assert_includes(dot, "label=\"lazy\"")
    assert_includes(dot, "label=\"/assets/styles_app_css.abc123.css\\ntext/css\"")
    assert_includes(dot, "style=\"dotted\"")
    assert_includes(dot, "label=\"asset\"")
  end

  def test_can_hide_asset_nodes_and_edges
    dot = Klenod::Build::Graphviz.call(sample_bundle, include_assets: false)

    refute_includes(dot, "/assets/styles_app_css.abc123.css")
    refute_includes(dot, "label=\"asset\"")
  end

  def test_relativizes_absolute_source_paths_under_source_root
    modules = {
      "entry.rb" => Klenod::Runtime::ModuleSpec.new(
        "entry.rb",
        "/app/src/entry.rb",
        "",
        {},
        nil,
        0,
        nil
      )
    }
    bundle = Klenod::Runtime::Bundle.new({"entry" => "entry.rb"}, modules, {}, source_root: "/app/src")

    dot = Klenod::Build::Graphviz.call(bundle)

    assert_includes(dot, "label=\"entry.rb\\nrb entrypoint\"")
    refute_includes(dot, "/app/src/entry.rb")
  end

  def test_links_assets_to_query_module_when_logical_name_omits_query
    modules = {
      "pages/assets/vegetables.jpg?width=360,720&format=jpeg" => Klenod::Runtime::ModuleSpec.new(
        "pages/assets/vegetables.jpg?width=360,720&format=jpeg",
        "pages/assets/vegetables.jpg",
        "",
        {},
        nil,
        0,
        nil
      )
    }
    asset = Klenod::Runtime::AssetSpec.new(
      "pages/assets/vegetables.jpg",
      "abc123",
      "/assets/vegetables.720w.abc123.jpeg",
      "image/jpeg",
      {type: :image_variant}
    )
    bundle = Klenod::Runtime::Bundle.new({}, modules, {asset.output_path => asset})

    dot = Klenod::Build::Graphviz.call(bundle)

    assert_includes(dot, "#{node_id("pages/assets/vegetables.jpg?width=360,720&format=jpeg")} -> #{asset_node_id(asset)}")
  end

  def test_links_google_font_assets_to_generated_google_fonts_css_asset
    google_fonts_url = "https://fonts.googleapis.com/css2?family=Source+Sans+3&display=swap"
    font_url = "https://fonts.gstatic.com/s/source/v1/font.ttf"
    module_id = "virtual:klenod/google_fonts/abc.rb?#{URI.encode_www_form("url" => google_fonts_url)}"
    modules = {
      module_id => Klenod::Runtime::ModuleSpec.new(
        module_id,
        "virtual:klenod/google_fonts/abc.rb",
        "CSS_CLASSES = {}.freeze\nCSS_ASSET_PATH = \"/assets/google_fonts_source_sans_3.def456.css\"\n",
        {},
        nil,
        0,
        nil
      )
    }
    css_asset = Klenod::Runtime::AssetSpec.new(
      module_id,
      "def456",
      "/assets/google_fonts_source_sans_3.def456.css",
      "text/css",
      {type: :css, google_fonts: true, font_source_urls: [font_url]}
    )
    font_asset = Klenod::Runtime::AssetSpec.new(
      font_url,
      "abc123",
      "/assets/google_font_source_sans_3_normal_400.abc123.ttf",
      "font/ttf",
      {type: :font, google_fonts: true, source_url: font_url}
    )
    bundle =
      Klenod::Runtime::Bundle.new(
        {},
        modules,
        {
          css_asset.output_path => css_asset,
          font_asset.output_path => font_asset
        }
      )

    dot = Klenod::Build::Graphviz.call(bundle)

    assert_includes(dot, "#{asset_node_id(css_asset)} -> #{asset_node_id(font_asset)}")
  end

  private

  def node_id(id)
    "mod_#{dot_identifier(id)}"
  end

  def asset_node_id(asset)
    "asset_#{dot_identifier(asset.output_path)}"
  end

  def dot_identifier(value)
    value.to_s.bytes.map { |byte| byte.to_s(16).rjust(2, "0") }.join
  end

  def sample_bundle
    modules = {
      "entry.rb" => Klenod::Runtime::ModuleSpec.new(
        "entry.rb",
        "entry.rb",
        "",
        {
          "card" => Klenod::Runtime::ImportSpec.new("components/Card.haml", Klenod::Runtime::DefaultImport.new(:Default), true),
          "router" => Klenod::Runtime::ImportSpec.new("virtual:router", nil, false)
        },
        nil,
        0,
        nil
      ),
      "components/Card.haml" => Klenod::Runtime::ModuleSpec.new(
        "components/Card.haml",
        "components/Card.haml",
        "",
        {
          "styles" => Klenod::Runtime::ImportSpec.new("styles/app.css", nil, true)
        },
        nil,
        0,
        nil
      ),
      "styles/app.css" => Klenod::Runtime::ModuleSpec.new(
        "styles/app.css",
        "styles/app.css",
        "",
        {},
        nil,
        0,
        nil
      ),
      "virtual:router" => Klenod::Runtime::ModuleSpec.new(
        "virtual:router",
        "virtual:router",
        "",
        {},
        nil,
        0,
        nil
      )
    }
    assets = {
      "/assets/styles_app_css.abc123.css" => Klenod::Runtime::AssetSpec.new(
        "styles/app.css",
        "abc123",
        "/assets/styles_app_css.abc123.css",
        "text/css",
        {type: :stylesheet}
      )
    }
    Klenod::Runtime::Bundle.new({"entry" => "entry.rb"}, modules, assets, source_root: "/app/src")
  end
end
