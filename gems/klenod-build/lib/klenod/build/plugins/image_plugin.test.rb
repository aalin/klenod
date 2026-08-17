# frozen_string_literal: true

require "fileutils"
require "rmagick"
require "minitest/autorun"
require "tmpdir"

require_relative "../context"
require "klenod/runtime"
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
          IMAGE_CONTENT_TYPE = Logo.content_type
        RUBY
      )

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.evaluate("entry")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)
      asset = context.assets_for("images/logo.png").fetch(0)

      assert_match(%r{\A/assets/logo\.[a-f0-9]{16}\.png\z}, exports::IMAGE_SRC)
      assert_equal(2, exports::IMAGE_WIDTH)
      assert_equal(3, exports::IMAGE_HEIGHT)
      assert_equal("image/png", exports::IMAGE_CONTENT_TYPE)
      assert_equal(2, asset.metadata[:width])
      assert_equal(3, asset.metadata[:height])
      assert_equal(:png, asset.metadata[:format])
    end
  end

  def test_image_import_emits_javascript_metadata_asset
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/images")
      File.binwrite("#{dir}/images/logo.png", png_bytes(width: 2, height: 3))
      File.write("#{dir}/entry.rb", "Logo = import(\"images/logo.png\")\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      context.evaluate("entry")
      image_asset = context.assets_for("images/logo.png").find { it.metadata[:type] == :image }
      javascript_asset = context.assets_for("images/logo.png").find { it.metadata[:type] == :image_javascript_metadata && it.metadata[:image_metadata] }
      metadata_source = javascript_asset.bytes

      assert_equal("#{image_asset.output_path}.js", javascript_asset.output_path)
      assert_equal("application/javascript", javascript_asset.content_type)
      assert_includes(metadata_source, image_asset.output_path)
      assert_includes(metadata_source, %("width":2))
      assert_includes(metadata_source, %("height":3))
      assert_includes(metadata_source, %("contentType":"image/png"))
    end
  end

  def test_image_import_does_not_read_full_source_with_file_binread
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/images")
      image_path = "#{dir}/images/logo.png"
      File.binwrite(image_path, png_bytes(width: 2, height: 3))
      File.write("#{dir}/entry.rb", "Logo = import(\"images/logo.png\")\n")
      context = Klenod::Build::Context.new(source_dir: dir)

      without_file_binread(image_path) do
        context.evaluate("entry")
      end
    end
  end

  def test_ruby_import_of_image_returns_default_export
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/images")
      File.binwrite("#{dir}/images/logo.png", png_bytes(width: 2, height: 3))
      File.write(
        "#{dir}/entry.rb",
        <<~RUBY
          Logo = import("images/logo.png")
          IMAGE = Logo
        RUBY
      )

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.evaluate("entry")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_match(%r{\A/assets/logo\.[a-f0-9]{16}\.png\z}, exports::IMAGE.src)
      refute_match(/::Exports\z/, exports::IMAGE.inspect)
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

      refute_equal("Klenod::Build::Plugins::ImagePlugin::Image", image.class.name)
      refute_match(/::Exports\z/, image.inspect)
      assert(loaded.modules.key?("virtual:/klenod/image.rb"))
      assert_equal(4, image.width)
      assert_equal(5, image.height)
      assert_equal("image/png", image.content_type)
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
          SRCSET = Hero.srcset
          SIZES = Hero.sizes
        RUBY
      )
      image_plugin = Klenod::Build::Plugins::ImagePlugin::Plugin.new(widths: [2], formats: ["png"])
      context =
        Klenod::Build::Context.new(
          source_dir: dir,
          plugins: [Klenod::Build::Plugins::RubyPlugin::Plugin.new, image_plugin]
        )

      record = context.evaluate("entry")
      variants = context.graph.mods.fetch(record.id).const_get(:Exports)::VARIANTS
      srcset = context.graph.mods.fetch(record.id).const_get(:Exports)::SRCSET
      sizes = context.graph.mods.fetch(record.id).const_get(:Exports)::SIZES
      variant = variants.fetch(0)
      variant_asset = context.assets_for("images/hero.png").find { |asset| asset.metadata[:type] == :image_variant }

      assert_match(%r{\A/assets/hero\.2w\.[a-f0-9]{16}\.png\z}, variant.src)
      assert_equal(2, variant.width)
      assert_equal(1, variant.height)
      assert_equal("image/png", variant.content_type)
      assert_equal(:png, variant.format)
      assert_equal("2w", variant.descriptor)
      assert_equal("#{variant.src} 2w", srcset)
      assert_equal("(max-width: 2px) 100vw, 2px", sizes)
      assert_equal(variant.src, variant_asset.output_path)
      assert_equal("image/png", variant_asset.content_type)
      assert_equal(:cpu, variant_asset.queue_kind)
      refute(variant_asset.ready?)
      assert_match(/\A.PNG/, variant_asset.bytes)
      assert(variant_asset.ready?)
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
            Klenod::Build::Plugins::RubyPlugin::Plugin.new,
            Klenod::Build::Plugins::ImagePlugin::Plugin.new
          ]
        )

      record = context.evaluate("entry")
      variants = context.graph.mods.fetch(record.id).const_get(:Exports)::VARIANTS
      variant = variants.fetch(0)
      assets = context.assets_for("images/hero.png")
      variant_asset = assets.find { |asset| asset.metadata[:type] == :image_variant }

      assert_equal(3, assets.length)
      assert_match(%r{\A/assets/hero\.2w\.[a-f0-9]{16}\.png\z}, variant.src)
      assert_equal(2, variant.width)
      assert_equal(1, variant.height)
      assert_equal("2w", variant.descriptor)
      refute(variant_asset.ready?)
    end
  end

  def test_ruby_import_query_format_updates_default_image_src
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/images")
      File.binwrite("#{dir}/images/hero.png", real_png_bytes(width: 4, height: 2))
      File.write(
        "#{dir}/entry.rb",
        <<~RUBY
          Hero = import("images/hero.png?width=2&format=webp")
          IMAGE = Hero
        RUBY
      )
      context =
        Klenod::Build::Context.new(
          source_dir: dir,
          plugins: [
            Klenod::Build::Plugins::RubyPlugin::Plugin.new,
            Klenod::Build::Plugins::ImagePlugin::Plugin.new
          ]
        )

      record = context.evaluate("entry")
      image = context.graph.mods.fetch(record.id).const_get(:Exports)::IMAGE
      assets = context.assets_for("images/hero.png")
      default_asset = assets.find { |asset| asset.metadata[:type] == :image }
      variant = image.variants.fetch(0)

      assert_equal(3, assets.length)
      assert_match(%r{\A/assets/hero\.[a-f0-9]{16}\.webp\z}, image.src)
      assert_equal("image/webp", image.content_type)
      assert_equal(4, image.width)
      assert_equal(2, image.height)
      assert_equal(image.src, default_asset.output_path)
      assert_equal("image/webp", default_asset.content_type)
      assert_equal(:webp, default_asset.metadata[:format])
      assert_equal(:cpu, default_asset.queue_kind)
      refute(default_asset.ready?)
      assert_match(%r{\A/assets/hero\.2w\.[a-f0-9]{16}\.webp\z}, variant.src)
      assert_equal("image/webp", variant.content_type)
    end
  end

  def test_ruby_import_query_quality_generates_default_image_src
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/images")
      File.binwrite("#{dir}/images/hero.png", real_png_bytes(width: 4, height: 2))
      File.write(
        "#{dir}/entry.rb",
        <<~RUBY
          Hero = import("images/hero.png?width=2&quality=75")
          IMAGE = Hero
        RUBY
      )
      context =
        Klenod::Build::Context.new(
          source_dir: dir,
          plugins: [
            Klenod::Build::Plugins::RubyPlugin::Plugin.new,
            Klenod::Build::Plugins::ImagePlugin::Plugin.new
          ]
        )

      record = context.evaluate("entry")
      image = context.graph.mods.fetch(record.id).const_get(:Exports)::IMAGE
      assets = context.assets_for("images/hero.png")
      default_asset = assets.find { |asset| asset.metadata[:type] == :image }
      variant_asset = assets.find { |asset| asset.metadata[:type] == :image_variant }

      assert_equal(3, assets.length)
      assert_match(%r{\A/assets/hero\.[a-f0-9]{16}\.png\z}, image.src)
      assert_equal("image/png", image.content_type)
      assert_equal(image.src, default_asset.output_path)
      assert_equal(75, default_asset.metadata[:quality])
      assert_equal(75, variant_asset.metadata[:quality])
      assert_equal(:cpu, default_asset.queue_kind)
      refute(default_asset.ready?)
    end
  end

  def test_ruby_import_query_quality_changes_generated_asset_hashes
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/images")
      File.binwrite("#{dir}/images/hero.png", real_png_bytes(width: 4, height: 2))
      File.write("#{dir}/entry_a.rb", "Hero = import(\"images/hero.png?width=2&quality=70\")\nIMAGE = Hero\n")
      File.write("#{dir}/entry_b.rb", "Hero = import(\"images/hero.png?width=2&quality=80\")\nIMAGE = Hero\n")
      image_plugin = Klenod::Build::Plugins::ImagePlugin::Plugin.new
      context =
        Klenod::Build::Context.new(
          source_dir: dir,
          plugins: [Klenod::Build::Plugins::RubyPlugin::Plugin.new, image_plugin]
        )

      record_a = context.evaluate("entry_a")
      record_b = context.evaluate("entry_b")
      image_a = context.graph.mods.fetch(record_a.id).const_get(:Exports)::IMAGE
      image_b = context.graph.mods.fetch(record_b.id).const_get(:Exports)::IMAGE
      variant_a = image_a.variants.fetch(0)
      variant_b = image_b.variants.fetch(0)

      refute_equal(image_a.src, image_b.src)
      refute_equal(variant_a.src, variant_b.src)
      assert_equal(70, context.asset(image_a.src).metadata[:quality])
      assert_equal(80, context.asset(image_b.src).metadata[:quality])
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
      image_plugin = Klenod::Build::Plugins::ImagePlugin::Plugin.new
      context =
        Klenod::Build::Context.new(
          source_dir: dir,
          plugins: [Klenod::Build::Plugins::RubyPlugin::Plugin.new, image_plugin]
        )

      record_a = context.evaluate("entry_a")
      record_b = context.evaluate("entry_b")
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

  def test_runtime_bundle_preserves_explicitly_formatted_default_image
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/images")
      File.binwrite("#{dir}/images/hero.png", real_png_bytes(width: 6, height: 3))
      File.write("#{dir}/entry.rb", "Hero = import(\"images/hero.png?width=3&format=png\")\nIMAGE = Hero\n")
      output = "#{dir}/bundle.mpk"
      context =
        Klenod::Build::Context.new(
          source_dir: dir,
          plugins: [
            Klenod::Build::Plugins::RubyPlugin::Plugin.new,
            Klenod::Build::Plugins::ImagePlugin::Plugin.new
          ]
        )

      bundle = context.build(entrypoints: ["entry"], output: output)
      loaded = Klenod::Runtime.load_bundle(output)
      image = loaded.load("entry").const_get(:Exports)::IMAGE
      default_asset = bundle.assets_for("images/hero.png").find { |asset| asset.metadata[:type] == :image }

      assert_match(%r{\A/assets/hero\.[a-f0-9]{16}\.png\z}, image.src)
      assert_equal("image/png", image.content_type)
      assert_equal(6, image.width)
      assert_equal(3, image.height)
      assert_equal(image.src, default_asset.output_path)
      assert_equal("image/png", default_asset.content_type)
      assert_equal(:image, default_asset.metadata[:type])
      assert_equal(:png, default_asset.metadata[:format])
    end
  end

  def test_runtime_bundle_preserves_image_variants
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/images")
      File.binwrite("#{dir}/images/hero.png", real_png_bytes(width: 6, height: 3))
      File.write("#{dir}/entry.rb", "Hero = import(\"images/hero.png\")\nVARIANTS = Hero.variants\n")
      output = "#{dir}/bundle.mpk"
      image_plugin = Klenod::Build::Plugins::ImagePlugin::Plugin.new(widths: [3], formats: ["png"])
      context =
        Klenod::Build::Context.new(
          source_dir: dir,
          plugins: [Klenod::Build::Plugins::RubyPlugin::Plugin.new, image_plugin]
        )

      bundle = context.build(entrypoints: ["entry"], output: output)
      loaded = Klenod::Runtime.load_bundle(output)
      variants = loaded.load("entry").const_get(:Exports)::VARIANTS
      variant_asset = context.assets_for("images/hero.png").find { |asset| asset.metadata[:type] == :image_variant }

      assert_equal(3, bundle.assets_for("images/hero.png").length)
      assert_equal(1, variants.length)
      assert_equal(3, variants.first.width)
      assert_equal(2, variants.first.height)
      assert_equal("image/png", variants.first.content_type)
      assert(variant_asset.ready?)
    end
  end

  def test_lazy_ruby_import_of_image_defers_asset_until_called
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/images")
      File.binwrite("#{dir}/images/logo.png", png_bytes(width: 2, height: 3))
      File.write(
        "#{dir}/entry.rb",
        <<~RUBY
          Logo = lazy_import("images/logo.png")

          def self.image_size
            image = Logo.call
            [image.width, image.height]
          end
        RUBY
      )

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.evaluate("entry")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_equal([], context.assets_for("images/logo.png"))
      refute(exports::Logo.loaded?)

      assert_equal([2, 3], exports.image_size)
      assert_equal(2, context.assets_for("images/logo.png").length)
      assert(exports::Logo.loaded?)
    end
  end

  def test_lazy_image_import_value_updates_after_loaded_image_changes
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/images")
      image_path = "#{dir}/images/logo.png"
      File.binwrite(image_path, png_bytes(width: 2, height: 3))
      File.write(
        "#{dir}/entry.rb",
        <<~RUBY
          Logo = lazy_import("images/logo.png")

          def self.image_size
            image = Logo.call
            [image.width, image.height]
          end
        RUBY
      )

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.evaluate("entry")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_equal([2, 3], exports.image_size)

      File.binwrite(image_path, png_bytes(width: 5, height: 7))
      result = context.invalidate_paths([image_path])
      updated_exports = context.graph.mods.fetch(record.id).const_get(:Exports)

      assert_equal(["app:/images/logo.png"], result.reloaded_module_ids.map(&:to_s))
      assert_equal(["app:/entry.rb"], result.reevaluated_module_ids.map(&:to_s))
      refute(updated_exports::Logo.loaded?)
      assert_equal([5, 7], updated_exports.image_size)
    end
  end

  def test_image_variant_invalidation_removes_stale_mirrored_assets
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/images")
      image_path = "#{dir}/images/hero.png"
      assets_dir = "#{dir}/public"
      File.binwrite(image_path, real_png_bytes(width: 4, height: 2))
      File.write("#{dir}/entry.rb", "Hero = import(\"images/hero.png\")\nVARIANTS = Hero.variants\n")
      context =
        Klenod::Build::Context.new(
          source_dir: dir,
          plugins: [
            Klenod::Build::Plugins::RubyPlugin::Plugin.new,
            Klenod::Build::Plugins::ImagePlugin::Plugin.new(widths: [2], formats: ["png"])
          ]
        )

      context.evaluate("entry")
      old_assets = context.assets_for("images/hero.png")
      old_original = old_assets.find { |asset| asset.metadata[:type] == :image }
      old_variant = old_assets.find { |asset| asset.metadata[:type] == :image_variant }
      old_original_disk_path = File.join(assets_dir, old_original.output_path.delete_prefix("/"))
      old_variant_disk_path = File.join(assets_dir, old_variant.output_path.delete_prefix("/"))

      write_result = context.write_assets(assets_dir)

      assert_includes(write_result.written_paths, old_original_disk_path)
      assert_includes(write_result.written_paths, old_variant_disk_path)
      assert(File.exist?(old_original_disk_path))
      assert(File.exist?(old_variant_disk_path))

      File.binwrite(image_path, real_png_bytes(width: 8, height: 4))
      result = context.invalidate_paths([image_path])
      new_assets = context.assets_for("images/hero.png")
      new_original = new_assets.find { |asset| asset.metadata[:type] == :image }
      new_variant = new_assets.find { |asset| asset.metadata[:type] == :image_variant }
      new_original_disk_path = File.join(assets_dir, new_original.output_path.delete_prefix("/"))
      new_variant_disk_path = File.join(assets_dir, new_variant.output_path.delete_prefix("/"))

      assert_equal(["app:/images/hero.png"], result.reloaded_module_ids.map(&:to_s))
      assert_includes(result.removed_assets, old_original.output_path)
      assert_includes(result.removed_assets, old_variant.output_path)
      assert_includes(result.added_assets, new_original.output_path)
      assert_includes(result.added_assets, new_variant.output_path)
      assert_raises(KeyError) { context.asset(old_original.output_path) }
      assert_raises(KeyError) { context.asset(old_variant.output_path) }

      update_write_result = context.write_asset_updates(result.asset_updates, assets_dir: assets_dir)

      assert_includes(update_write_result.removed_paths, old_original_disk_path)
      assert_includes(update_write_result.removed_paths, old_variant_disk_path)
      assert_includes(update_write_result.written_paths, new_original_disk_path)
      assert_includes(update_write_result.written_paths, new_variant_disk_path)
      refute(File.exist?(old_original_disk_path))
      refute(File.exist?(old_variant_disk_path))
      assert(File.exist?(new_original_disk_path))
      assert(File.exist?(new_variant_disk_path))
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

  def without_file_binread(disallowed_path)
    singleton = class << File; self; end
    original = File.method(:binread)
    previous_verbose = $VERBOSE
    $VERBOSE = nil
    singleton.define_method(:binread) do |path, *args, **kwargs, &block|
      raise "File.binread should not be used for #{disallowed_path}" if path.to_s == disallowed_path

      original.call(path, *args, **kwargs, &block)
    end
    $VERBOSE = previous_verbose
    yield
  ensure
    $VERBOSE = nil
    singleton.define_method(:binread) do |*args, **kwargs, &block|
      original.call(*args, **kwargs, &block)
    end
    $VERBOSE = previous_verbose
  end
end
