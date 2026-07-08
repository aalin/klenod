# frozen_string_literal: true

require "fileutils"
require "rmagick"
require "minitest/autorun"
require "tmpdir"

require_relative "../context"
require_relative "ruby_plugin"

class Klenod::Build::Plugins::ImagePlugin::Test < Minitest::Test
  def test_ruby_import_of_image_returns_dimensions
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/images")
      File.binwrite("#{dir}/images/logo.png", png_bytes(width: 2, height: 3))
      File.write(
        "#{dir}/entry.rb",
        <<~RUBY
          Logo = import("images/logo.png")
          IMAGE_SRC = Logo.src
          IMAGE_WIDTH = Logo.width
          IMAGE_HEIGHT = Logo.height
        RUBY
      )

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.load("entry")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)
      asset = context.assets_for("images/logo.png").fetch(0)

      assert_match(%r{\A/assets/logo\.[a-f0-9]{16}\.png\z}, exports::IMAGE_SRC)
      assert_equal(2, exports::IMAGE_WIDTH)
      assert_equal(3, exports::IMAGE_HEIGHT)
      assert_equal(2, asset.metadata[:width])
      assert_equal(3, asset.metadata[:height])
      assert_equal(:png, asset.metadata[:format])
    end
  end

  def test_runtime_bundle_preserves_image_import_value_and_metadata
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/images")
      File.binwrite("#{dir}/images/logo.png", png_bytes(width: 4, height: 5))
      File.write(
        "#{dir}/entry.rb",
        <<~RUBY
          Logo = import("images/logo.png")
          IMAGE = Logo
        RUBY
      )
      output = "#{dir}/bundle.mpk"

      context = Klenod::Build::Context.new(source_dir: dir)
      bundle = context.build(entrypoints: ["entry"], output: output)
      loaded = Klenod::Runtime.load_bundle(output)
      image = loaded.load("entry").const_get(:Exports)::IMAGE
      asset = loaded.assets_for("images/logo.png").fetch(0)

      assert_equal(4, image.width)
      assert_equal(5, image.height)
      assert_equal(4, asset.metadata[:width])
      assert_equal(5, asset.metadata[:height])
      assert_equal(bundle.assets.keys, loaded.assets.keys)
    end
  end

  def test_ruby_import_of_image_returns_generated_variants
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/images")
      File.binwrite("#{dir}/images/hero.png", real_png_bytes(width: 4, height: 2))
      File.write(
        "#{dir}/entry.rb",
        <<~RUBY
          Hero = import("images/hero.png")
          VARIANTS = Hero.variants
        RUBY
      )
      image_plugin = Klenod::Build::Plugins::ImagePlugin.new(widths: [2], formats: ["png"])
      context =
        Klenod::Build::Context.new(
          source_dir: dir,
          plugins: [Klenod::Build::Plugins::RubyPlugin.new, image_plugin]
        )

      record = context.load("entry")
      variants = context.graph.mods.fetch(record.id).const_get(:Exports)::VARIANTS
      variant = variants.fetch(0)
      variant_asset = context.assets_for("images/hero.png").find { |asset| asset.metadata[:type] == :image_variant }

      assert_match(%r{\A/assets/hero\.2w\.[a-f0-9]{16}\.png\z}, variant.src)
      assert_equal(2, variant.width)
      assert_equal(1, variant.height)
      assert_equal(:png, variant.format)
      assert_equal("2w", variant.descriptor)
      assert_equal(variant.src, variant_asset.output_path)
      assert_equal("image/png", variant_asset.content_type)
    end
  end

  def test_ruby_import_query_generates_image_variants
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/images")
      File.binwrite("#{dir}/images/hero.png", real_png_bytes(width: 4, height: 2))
      File.write(
        "#{dir}/entry.rb",
        <<~RUBY
          Hero = import("images/hero.png?width=2&format=png")
          VARIANTS = Hero.variants
        RUBY
      )
      context =
        Klenod::Build::Context.new(
          source_dir: dir,
          plugins: [
            Klenod::Build::Plugins::RubyPlugin.new,
            Klenod::Build::Plugins::ImagePlugin.new
          ]
        )

      record = context.load("entry")
      variants = context.graph.mods.fetch(record.id).const_get(:Exports)::VARIANTS
      variant = variants.fetch(0)
      assets = context.assets_for("images/hero.png")

      assert_equal(2, assets.length)
      assert_match(%r{\A/assets/hero\.2w\.[a-f0-9]{16}\.png\z}, variant.src)
      assert_equal(2, variant.width)
      assert_equal(1, variant.height)
      assert_equal("2w", variant.descriptor)
    end
  end

  def test_overlapping_image_import_queries_reuse_generated_variants
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/images")
      File.binwrite("#{dir}/images/hero.png", real_png_bytes(width: 6, height: 3))
      File.write(
        "#{dir}/entry_a.rb",
        <<~RUBY
          HeroA = import("images/hero.png?width=2,3&format=png")
          VARIANTS_A = HeroA.variants
        RUBY
      )
      File.write(
        "#{dir}/entry_b.rb",
        <<~RUBY
          HeroB = import("images/hero.png?width=3&format=png")
          VARIANTS_B = HeroB.variants
        RUBY
      )
      image_plugin = Klenod::Build::Plugins::ImagePlugin.new
      context =
        Klenod::Build::Context.new(
          source_dir: dir,
          plugins: [Klenod::Build::Plugins::RubyPlugin.new, image_plugin]
        )

      record_a = context.load("entry_a")
      record_b = context.load("entry_b")
      variants_a = context.graph.mods.fetch(record_a.id).const_get(:Exports)::VARIANTS_A
      variants_b = context.graph.mods.fetch(record_b.id).const_get(:Exports)::VARIANTS_B
      shared_variant_a = variants_a.find { |variant| variant.descriptor == "3w" }
      shared_variant_b = variants_b.fetch(0)
      generated_3w_assets =
        context
          .assets_for("images/hero.png")
          .select { |asset| asset.metadata[:type] == :image_variant && asset.metadata[:descriptor] == "3w" }

      assert_equal(shared_variant_a.src, shared_variant_b.src)
      assert_equal(1, generated_3w_assets.length)
      assert_equal(shared_variant_b.src, generated_3w_assets.fetch(0).output_path)
    end
  end

  def test_runtime_bundle_preserves_image_variants
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/images")
      File.binwrite("#{dir}/images/hero.png", real_png_bytes(width: 6, height: 3))
      File.write("#{dir}/entry.rb", "Hero = import(\"images/hero.png\")\nVARIANTS = Hero.variants\n")
      output = "#{dir}/bundle.mpk"
      image_plugin = Klenod::Build::Plugins::ImagePlugin.new(widths: [3], formats: ["png"])
      context =
        Klenod::Build::Context.new(
          source_dir: dir,
          plugins: [Klenod::Build::Plugins::RubyPlugin.new, image_plugin]
        )

      bundle = context.build(entrypoints: ["entry"], output: output)
      loaded = Klenod::Runtime.load_bundle(output)
      variants = loaded.load("entry").const_get(:Exports)::VARIANTS

      assert_equal(2, bundle.assets_for("images/hero.png").length)
      assert_equal(1, variants.length)
      assert_equal(3, variants.first.width)
      assert_equal(2, variants.first.height)
    end
  end

  private

  def real_png_bytes(width:, height:)
    image = Magick::Image.new(width, height) { |info| info.background_color = "red" }
    image.to_blob { |info| info.format = "PNG" }
  ensure
    image&.destroy!
  end

  def png_bytes(width:, height:)
    signature = "\x89PNG\r\n\x1a\n".b
    ihdr_data = [width, height, 8, 2, 0, 0, 0].pack("NNCCCCC")
    ihdr = [ihdr_data.bytesize].pack("N") + "IHDR" + ihdr_data + [0].pack("N")
    iend = [0].pack("N") + "IEND" + [0].pack("N")

    signature + ihdr + iend
  end
end
