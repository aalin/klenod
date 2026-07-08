# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "../context"

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

  private

  def png_bytes(width:, height:)
    signature = "\x89PNG\r\n\x1a\n".b
    ihdr_data = [width, height, 8, 2, 0, 0, 0].pack("NNCCCCC")
    ihdr = [ihdr_data.bytesize].pack("N") + "IHDR" + ihdr_data + [0].pack("N")
    iend = [0].pack("N") + "IEND" + [0].pack("N")

    signature + ihdr + iend
  end
end
