# frozen_string_literal: true

require "minitest/autorun"

require_relative "mod"
require_relative "bundle"

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

  def test_marshal_round_trip_preserves_identity_fields
    mod = Klenod::Runtime::Mod.new("entry.rb", "VALUE = 1", version: 3)
    copy = Marshal.load(Marshal.dump(mod))

    assert_equal("entry.rb", copy.path)
    assert_equal(3, copy.version)
    assert_equal(mod.constant_name, copy.constant_name)
    assert_equal(1, copy.const_get(:Exports)::VALUE)
  end

  def test_bundle_load_instantiates_imported_modules
    bundle =
      Klenod::Runtime::Bundle.new(
        {"entry" => "entry.rb"},
        {
          "dep.rb" =>
            Klenod::Runtime::ModuleSpec.new(
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
    assert_equal(41, bundle.mod("dep.rb").const_get(:Exports)::VALUE)
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
end
