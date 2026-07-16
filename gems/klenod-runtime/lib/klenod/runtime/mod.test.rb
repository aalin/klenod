# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tempfile"
require "tmpdir"

require_relative "mod"
require_relative "bundle"
require_relative "../runtime"

class Klenod::Runtime::Mod::Test < Minitest::Test
  def test_evaluates_exports_with_import_helper
    mod =
      Klenod::Runtime::Mod.new(
        "entry.rb",
        "VALUE = __klenod_import__(\"dep\") + 1",
        imports: {"dep" => 41}
      )

    assert_equal(42, mod.const_get(:Exports)::VALUE)
    assert_match(/\AMod_/, mod.constant_name)
    assert_same(mod, Klenod::Runtime::Generated.const_get(mod.constant_name))
  end

  def test_evaluates_exports_with_lazy_import_helper
    lazy = Klenod::Runtime::LazyImport.new { 41 }
    mod =
      Klenod::Runtime::Mod.new(
        "entry.rb",
        "DEP = __klenod_lazy_import__(\"dep\")\nVALUE = DEP.call + 1",
        imports: {"dep" => lazy}
      )

    assert_equal(42, mod.const_get(:Exports)::VALUE)
    assert(lazy.loaded?)
  end

  def test_marshal_round_trip_preserves_identity_fields
    mod = Klenod::Runtime::Mod.new("entry.rb", "VALUE = 1", version: 3)
    copy = Marshal.load(Marshal.dump(mod))

    assert_equal("entry.rb", copy.path)
    assert_equal("entry.rb", copy.eval_path)
    assert_equal(3, copy.version)
    assert_equal(mod.constant_name, copy.constant_name)
    assert_equal(1, copy.const_get(:Exports)::VALUE)
  end

  def test_mod_uses_eval_path_for_file_constant
    mod =
      Klenod::Runtime::Mod.new(
        "entry.rb",
        "FILE_PATH = __FILE__",
        eval_path: "/app/src/entry.rb"
      )

    assert_equal("/app/src/entry.rb", mod.eval_path)
    assert_equal("/app/src/entry.rb", mod.const_get(:Exports)::FILE_PATH)
  end

  def test_bundle_rebases_eval_paths_after_format_load
    bundle =
      Klenod::Runtime::Bundle.new(
        {"entry" => "pages/page.rb"},
        {
          "pages/page.rb" =>
            Klenod::Runtime::ModuleSpec.new(
              "pages/page.rb",
              "pages/page.rb",
              "FILE_PATH = __FILE__",
              {},
              nil,
              0,
              Klenod::Runtime::Mod.constant_name_for("pages/page.rb")
            )
        },
        {},
        source_root: "/build/src"
      )

    copy = Klenod::Runtime.load_bundle(StringIO.new(Klenod::Runtime::BundleFormat.dump(bundle)))
    assert_equal("/build/src/pages/page.rb", copy.load("entry").const_get(:Exports)::FILE_PATH)

    copy.source_root = "/app/src"

    assert_equal("/app/src/pages/page.rb", copy.load("entry").const_get(:Exports)::FILE_PATH)
    assert_equal("pages/page.rb", copy.module_id_for("/app/src/pages/page.rb"))
  end

  def test_bundle_load_instantiates_imported_modules
    bundle =
      Klenod::Runtime::Bundle.new(
        {"entry" => "entry.rb"},
        {
          "dep.rb" =>
            Klenod::Runtime::ModuleSpec.new(
              "dep.rb",
              "dep.rb",
              "VALUE = 41",
              {},
              nil,
              0,
              Klenod::Runtime::Mod.constant_name_for("dep.rb")
            ),
          "entry.rb" =>
            Klenod::Runtime::ModuleSpec.new(
              "entry.rb",
              "entry.rb",
              "Dep = __klenod_import__(\"dep\")\nVALUE = Dep::VALUE + 1",
              {"dep" => "dep.rb"},
              nil,
              0,
              Klenod::Runtime::Mod.constant_name_for("entry.rb")
            )
        },
        []
      )

    mod = bundle.load("entry")

    assert_equal(42, mod.const_get(:Exports)::VALUE)
    assert_same(mod.const_get(:Exports), bundle.exports("entry"))
    assert_equal(41, bundle.mod("dep.rb").const_get(:Exports)::VALUE)
  end

  def test_bundle_load_defers_lazy_imported_modules
    bundle =
      Klenod::Runtime::Bundle.new(
        {"entry" => "entry.rb"},
        {
          "dep.rb" =>
            Klenod::Runtime::ModuleSpec.new(
              "dep.rb",
              "dep.rb",
              "VALUE = 41",
              {},
              nil,
              0,
              Klenod::Runtime::Mod.constant_name_for("dep.rb")
            ),
          "entry.rb" =>
            Klenod::Runtime::ModuleSpec.new(
              "entry.rb",
              "entry.rb",
              "Dep = __klenod_lazy_import__(\"dep\")\ndef self.value = Dep.call::VALUE + 1",
              {"dep" => Klenod::Runtime::ImportSpec.new("dep.rb", nil, false)},
              nil,
              0,
              Klenod::Runtime::Mod.constant_name_for("entry.rb")
            )
        },
        []
      )

    mod = bundle.load("entry")
    exports = mod.const_get(:Exports)

    assert_raises(KeyError) { bundle.mod("dep.rb") }
    refute(exports::Dep.loaded?)
    assert_equal(42, exports.value)
    assert_equal(41, bundle.mod("dep.rb").const_get(:Exports)::VALUE)
    assert(exports::Dep.loaded?)
  end

  def test_runtime_load_bundle_accepts_io
    bundle =
      Klenod::Runtime::Bundle.new(
        {"entry" => "entry.rb"},
        {
          "entry.rb" =>
            Klenod::Runtime::ModuleSpec.new(
              "entry.rb",
              "entry.rb",
              "VALUE = 1",
              {},
              nil,
              0,
              Klenod::Runtime::Mod.constant_name_for("entry.rb")
            )
        },
        {}
      )

    payload = Klenod::Runtime::BundleFormat.dump(bundle)
    loaded = Klenod::Runtime.load_bundle(StringIO.new(payload))

    assert_equal(1, loaded.exports("entry")::VALUE)
    assert(payload.start_with?(Klenod::Runtime::BundleFormat::MAGIC))
  end

  def test_runtime_bundle_format_does_not_duplicate_transformed_source_in_source_maps
    source = "# SourceMapMark:1\nVALUE = 1\n"
    source_map = Klenod::Runtime::SourceMap::SourceMap.parse("VALUE = 1\n", source)
    bundle =
      Klenod::Runtime::Bundle.new(
        {"entry" => "entry.rb"},
        {
          "entry.rb" =>
            Klenod::Runtime::ModuleSpec.new(
              "entry.rb",
              "entry.rb",
              source,
              {},
              source_map,
              0,
              Klenod::Runtime::Mod.constant_name_for("entry.rb")
            )
        },
        {}
      )

    payload = Klenod::Runtime::BundleFormat.dump(bundle)
    parsed = JSON.parse(payload.delete_prefix(Klenod::Runtime::BundleFormat::MAGIC))
    loaded = Klenod::Runtime.load_bundle(StringIO.new(payload))

    refute_includes(parsed.fetch("modules").fetch("entry.rb").fetch("source_map"), "output")
    assert_equal(1, parsed.fetch("modules").fetch("entry.rb").fetch("source_map").fetch("marks_by_output_line").fetch("1"))
    assert_equal(source, loaded.load("entry").source_map.output)
  end

  def test_runtime_load_bundle_rejects_invalid_format
    error = assert_raises(Klenod::Runtime::BundleFormatError) do
      Klenod::Runtime.load_bundle(StringIO.new("not a klenod bundle"))
    end

    assert_includes(error.message, "Invalid Klenod bundle header")
  end

  def test_runtime_load_bundle_rejects_invalid_json
    error = assert_raises(Klenod::Runtime::BundleFormatError) do
      Klenod::Runtime.load_bundle(StringIO.new("#{Klenod::Runtime::BundleFormat::MAGIC}{"))
    end

    assert_includes(error.message, "Invalid Klenod bundle JSON")
  end

  def test_runtime_load_bundle_rejects_unsupported_format_version
    payload =
      JSON.generate(
        "format_version" => 999,
        "runtime_version" => Klenod::Runtime::VERSION,
        "entrypoints" => {},
        "modules" => {},
        "assets" => {}
      )

    error = assert_raises(Klenod::Runtime::BundleFormatError) do
      Klenod::Runtime.load_bundle(StringIO.new("#{Klenod::Runtime::BundleFormat::MAGIC}#{payload}"))
    end

    assert_includes(error.message, "Unsupported Klenod bundle format version")
  end

  def test_bundle_load_entrypoints_evaluates_each_entrypoint_once
    Dir.mktmpdir do |dir|
      result_path = "#{dir}/entries.txt"
      bundle =
        Klenod::Runtime::Bundle.new(
          {"one" => "one.rb", "two" => "two.rb"},
          {
            "one.rb" =>
              Klenod::Runtime::ModuleSpec.new(
                "one.rb",
                "one.rb",
                "File.open(#{result_path.inspect}, \"a\") { |file| file.write(\"one\\n\") }",
                {},
                nil,
                0,
                Klenod::Runtime::Mod.constant_name_for("one.rb")
              ),
            "two.rb" =>
              Klenod::Runtime::ModuleSpec.new(
                "two.rb",
                "two.rb",
                "File.open(#{result_path.inspect}, \"a\") { |file| file.write(\"two\\n\") }",
                {},
                nil,
                0,
                Klenod::Runtime::Mod.constant_name_for("two.rb")
              )
          },
          {}
        )

      bundle.load_entrypoints
      bundle.load_entrypoints

      assert_equal("one\ntwo\n", File.binread(result_path))
    end
  end

  def test_runtime_load_executable_bundle_reads_payload_after_end_marker
    bundle =
      Klenod::Runtime::Bundle.new(
        {"entry" => "entry.rb"},
        {
          "entry.rb" =>
            Klenod::Runtime::ModuleSpec.new(
              "entry.rb",
              "entry.rb",
              "VALUE = 1",
              {},
              nil,
              0,
              Klenod::Runtime::Mod.constant_name_for("entry.rb")
            )
        },
        {}
      )

    Tempfile.create("klenod-executable") do |file|
      file.binmode
      file.write("# encoding: ASCII-8BIT\n__END__\n")
      file.write(Klenod::Runtime::BundleFormat.dump(bundle))
      file.close

      loaded = Klenod::Runtime.load_executable_bundle(file.path)

      assert_equal(1, loaded.exports("entry")::VALUE)
    end
  end

  def test_bundle_asset_helpers
    asset =
      Klenod::Runtime::AssetSpec.new(
        "styles/home.css",
        "abc123",
        "/assets/home.abc123.css",
        "text/css",
        {}
      )
    bundle = Klenod::Runtime::Bundle.new({}, {}, {asset.output_path => asset})

    assert_same(asset, bundle.asset("/assets/home.abc123.css"))
    assert_equal([asset], bundle.assets_for("styles/home.css"))
    assert_equal([asset], bundle.each_asset.to_a)
    assert_raises(KeyError) { bundle.asset("/assets/missing.css") }
  end

  def test_bundle_assets_for_module_returns_reachable_filtered_assets
    root_css_asset =
      Klenod::Runtime::AssetSpec.new(
        "styles/root.css",
        "root123",
        "/assets/root.root123.css",
        "text/css",
        {type: :css}
      )
    layout_css_asset =
      Klenod::Runtime::AssetSpec.new(
        "styles/layout.css",
        "layout123",
        "/assets/layout.layout123.css",
        "text/css",
        {type: :css}
      )
    entry_css_asset =
      Klenod::Runtime::AssetSpec.new(
        "entry.rb",
        "entry123",
        "/assets/entry.entry123.css",
        "text/css",
        {type: :css}
      )
    css_asset =
      Klenod::Runtime::AssetSpec.new(
        "styles/card.css",
        "abc123",
        "/assets/card.abc123.css",
        "text/css",
        {type: :css}
      )
    image_asset =
      Klenod::Runtime::AssetSpec.new(
        "images/logo.png",
        "def456",
        "/assets/logo.def456.png",
        "image/png",
        {type: :image}
      )
    bundle =
      Klenod::Runtime::Bundle.new(
        {"entry" => "entry.rb"},
        {
          "styles/root.css" =>
            Klenod::Runtime::ModuleSpec.new(
              "styles/root.css",
              "styles/root.css",
              "",
              {},
              nil,
              0,
              Klenod::Runtime::Mod.constant_name_for("styles/root.css")
            ),
          "styles/layout.css" =>
            Klenod::Runtime::ModuleSpec.new(
              "styles/layout.css",
              "styles/layout.css",
              "",
              {"root" => Klenod::Runtime::ImportSpec.new("styles/root.css", nil, true)},
              nil,
              0,
              Klenod::Runtime::Mod.constant_name_for("styles/layout.css")
            ),
          "entry.rb" =>
            Klenod::Runtime::ModuleSpec.new(
              "entry.rb",
              "entry.rb",
              "",
              {"component" => Klenod::Runtime::ImportSpec.new("components/card.rb", nil, true)},
              nil,
              0,
              Klenod::Runtime::Mod.constant_name_for("entry.rb")
            ),
          "components/card.rb" =>
            Klenod::Runtime::ModuleSpec.new(
              "components/card.rb",
              "components/card.rb",
              "",
              {"styles" => Klenod::Runtime::ImportSpec.new("styles/card.css", {title: "title_hash"}, true)},
              nil,
              0,
              Klenod::Runtime::Mod.constant_name_for("components/card.rb")
            ),
          "styles/card.css" =>
            Klenod::Runtime::ModuleSpec.new(
              "styles/card.css",
              "styles/card.css",
              "",
              {},
              nil,
              0,
              Klenod::Runtime::Mod.constant_name_for("styles/card.css")
            )
        },
        {
          root_css_asset.output_path => root_css_asset,
          layout_css_asset.output_path => layout_css_asset,
          entry_css_asset.output_path => entry_css_asset,
          css_asset.output_path => css_asset,
          image_asset.output_path => image_asset
        }
      )

    assert_equal([entry_css_asset, css_asset], bundle.assets_for_module("entry.rb", type: :css))
    assert_equal([entry_css_asset, css_asset], bundle.assets_for_module("entry.rb", content_type: "text/css"))
    assert_equal([entry_css_asset], bundle.assets_for_module("entry.rb", type: :css, recursive: false))
    assert_equal([], bundle.assets_for_module("entry.rb", type: :image))
    assert_equal([root_css_asset, layout_css_asset, entry_css_asset, css_asset], bundle.assets_for_module(["styles/layout.css", "entry.rb"], type: :css))
    assert_equal(
      [
        Klenod::Runtime::AssetReference.new(index: 0, asset: root_css_asset),
        Klenod::Runtime::AssetReference.new(index: 1, asset: layout_css_asset),
        Klenod::Runtime::AssetReference.new(index: 2, asset: entry_css_asset),
        Klenod::Runtime::AssetReference.new(index: 4, asset: css_asset)
      ],
      bundle.asset_references_for_module(["styles/layout.css", "entry.rb"], type: :css)
    )
    assert_equal([layout_css_asset, entry_css_asset], bundle.assets_for_module(["styles/layout.css", "entry.rb"], type: :css, recursive: false))
    assert_equal([0, 1], bundle.asset_references_for_module(["styles/layout.css", "entry.rb"], type: :css, recursive: false).map(&:index))
  end
end
