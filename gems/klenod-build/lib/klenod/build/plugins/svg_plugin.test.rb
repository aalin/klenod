# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "../context"
require "klenod/plugin/css"
require "klenod/runtime"
require_relative "ruby_plugin"

class Klenod::Build::Plugins::SvgPlugin::Test < Minitest::Test
  def test_ruby_import_of_svg_returns_dimensions_from_width_and_height
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/images")
      File.write("#{dir}/images/logo.svg", svg(width: "24", height: "32", view_box: "0 0 48 64"))
      File.write(
        "#{dir}/entry.rb",
        <<~RUBY
          Logo = import("images/logo.svg")
          SVG_SRC = Logo.src
          SVG_WIDTH = Logo.width
          SVG_HEIGHT = Logo.height
          SVG_CONTENT_TYPE = Logo.content_type
          SVG_ASPECT_RATIO = Logo.aspect_ratio
          SVG_CLASS_NAME = Logo.class.name
        RUBY
      )

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.evaluate("entry")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)
      asset = context.assets_for("images/logo.svg").fetch(0)

      assert_match(%r{\A/assets/logo\.[a-f0-9]{16}\.svg\z}, exports::SVG_SRC)
      assert_equal(24, exports::SVG_WIDTH)
      assert_equal(32, exports::SVG_HEIGHT)
      assert_equal("image/svg+xml", exports::SVG_CONTENT_TYPE)
      assert_equal(0.75, exports::SVG_ASPECT_RATIO)
      assert_match(/::SvgMetadata\z/, exports::SVG_CLASS_NAME)
      assert_equal("image/svg+xml", asset.content_type)
      assert_equal(:svg, asset.metadata[:type])
      assert_equal(24, asset.metadata[:width])
      assert_equal(32, asset.metadata[:height])
    end
  end

  def test_non_javascript_svg_import_does_not_emit_javascript_metadata_asset
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/images")
      File.write("#{dir}/images/logo.svg", svg(width: "24", height: "32"))
      File.write("#{dir}/entry.rb", "Logo = import(\"images/logo.svg\")\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      context.evaluate("entry")
      javascript_asset = context.assets_for("images/logo.svg").find { it.metadata[:type] == :svg_javascript_metadata && it.metadata[:svg_metadata] }

      assert_nil(javascript_asset)
    end
  end

  def test_ruby_import_of_svg_uses_view_box_when_dimensions_are_missing
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/images")
      File.write("#{dir}/images/logo.svg", svg(view_box: "0 0 1024 1024"))
      File.write("#{dir}/entry.rb", "Logo = import(\"images/logo.svg\")\nSIZE = [Logo.width, Logo.height]\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.evaluate("entry")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_equal([1024, 1024], exports::SIZE)
    end
  end

  def test_ruby_import_of_svg_returns_default_export
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/images")
      File.write("#{dir}/images/logo.svg", svg(width: "24px", height: "32px"))
      File.write("#{dir}/entry.rb", "Logo = import(\"images/logo.svg\")\nSVG = Logo\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.evaluate("entry")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_match(%r{\A/assets/logo\.[a-f0-9]{16}\.svg\z}, exports::SVG.src)
      assert_equal(24, exports::SVG.width)
      assert_equal(32, exports::SVG.height)
      refute_match(/::Exports\z/, exports::SVG.inspect)
    end
  end

  def test_runtime_bundle_preserves_svg_import_value_and_metadata
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/images")
      File.write("#{dir}/images/logo.svg", svg(view_box: "0 0 48 64"))
      File.write("#{dir}/entry.rb", "Logo = import(\"images/logo.svg\")\nSVG = Logo\n")
      output = "#{dir}/bundle.mpk"

      context = Klenod::Build::Context.new(source_dir: dir)
      bundle = context.build(entrypoints: ["entry"], output: output)
      loaded = Klenod::Runtime.load_bundle(output)
      svg = loaded.load("entry").const_get(:Exports)::SVG
      asset = loaded.assets_for("images/logo.svg").fetch(0)

      assert_match(/::SvgMetadata\z/, svg.class.name)
      refute_match(/::Exports\z/, svg.inspect)
      assert(loaded.modules.key?("virtual:/klenod/svg.rb"))
      assert_equal(48, svg.width)
      assert_equal(64, svg.height)
      assert_equal("image/svg+xml", svg.content_type)
      assert_equal(0.75, svg.aspect_ratio)
      assert(svg.frozen?)
      assert_equal(48, asset.metadata[:width])
      assert_equal(64, asset.metadata[:height])
      assert_equal(bundle.assets.keys, loaded.assets.keys)
    end
  end

  def test_css_url_to_svg_rewrites_to_emitted_asset_path
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/styles")
      File.write("#{dir}/styles/logo.svg", svg(view_box: "0 0 16 20"))
      File.write("#{dir}/styles/home.css", ".logo { background-image: url(\"./logo.svg\"); }\n")

      context =
        Klenod::Build::Context.new(
          source_dir: dir,
          plugins: [
            Klenod::Build::Plugins::RubyPlugin.new,
            Klenod::Build::Plugins::CSSPlugin.new,
            Klenod::Build::Plugins::SvgPlugin.new
          ]
        )
      context.evaluate("styles/home.css")
      css_asset = context.assets_for("styles/home.css").fetch(0)
      svg_asset = context.assets_for("styles/logo.svg").fetch(0)

      assert_includes(css_asset.bytes, %(url("#{svg_asset.url}")))
      assert_equal("image/svg+xml", svg_asset.content_type)
      assert_equal(16, svg_asset.metadata[:width])
      assert_equal(20, svg_asset.metadata[:height])
    end
  end

  def test_svg_import_query_raises_unsupported_file_error
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/images")
      File.write("#{dir}/images/logo.svg", svg(view_box: "0 0 16 20"))
      File.write("#{dir}/entry.rb", "Logo = import(\"images/logo.svg?width=16\")\n")

      error = assert_raises(Klenod::Build::UnsupportedFileError) do
        Klenod::Build::Context.new(source_dir: dir).evaluate("entry")
      end

      assert_match(/SVG imports do not support query options/, error.message)
      assert_match(/images\/logo.svg\?width=16/, error.message)
    end
  end

  private

  def svg(width: nil, height: nil, view_box: nil)
    attributes = [
      %(xmlns="http://www.w3.org/2000/svg"),
      width && %(width="#{width}"),
      height && %(height="#{height}"),
      view_box && %(viewBox="#{view_box}")
    ].compact.join(" ")

    <<~SVG
      <svg #{attributes}>
        <rect width="100%" height="100%" />
      </svg>
    SVG
  end

  def test_malformed_markup_is_tolerated_with_unknown_dimensions
    # SVG is scraped with a regex rather than parsed, so an unclosed tag is not
    # an error -- it just means the dimensions are unknown.
    Dir.mktmpdir do |dir|
      File.write("#{dir}/logo.svg", "<svg><g><rect width='2'\n")
      File.write("#{dir}/entry.rb", "Logo = import(\"./logo.svg\")\n")

      Klenod::Build::Context.new(source_dir: dir).evaluate("entry.rb")
    end
  end

  def test_a_file_that_is_not_text_reports_the_module
    Dir.mktmpdir do |dir|
      File.binwrite("#{dir}/logo.svg", "\xFF\xFE\x00\x01junk\xC3\x28".b)
      File.write("#{dir}/entry.rb", "Logo = import(\"./logo.svg\")\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      error = assert_raises(Klenod::Build::Plugins::SvgPlugin::EncodingError) { context.evaluate("entry.rb") }

      assert_equal("SVG encoding error", error.kind)
      assert_equal("app:/logo.svg", error.module_id.to_s)
      assert_equal(["An SVG file must be valid UTF-8 text."], error.hints)
    end
  end
end
