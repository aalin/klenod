# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "../context"

class Klenod::Build::Plugins::StaticAssetPlugin::Test < Minitest::Test
  def test_imported_font_exports_a_content_addressed_url
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p("#{dir}/fonts")
      File.binwrite("#{dir}/fonts/example.ttf", "font bytes")
      File.write("#{dir}/entry.rb", "Font = import(\"fonts/example.ttf\")\n")

      context = Klenod::Build::Context.new(source_dir: dir)
      record = context.evaluate("entry")
      exports = context.graph.mods.fetch(record.id).const_get(:Exports)
      asset = context.assets_for("fonts/example.ttf").fetch(0)

      assert_match(%r{\A/assets/example\.[a-f0-9]{16}\.ttf\z}, exports::Font)
      assert_equal("font/ttf", asset.content_type)
      assert_equal("font bytes", asset.bytes)
    end
  end
end
