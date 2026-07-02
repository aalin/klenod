# frozen_string_literal: true

require "minitest/autorun"

require_relative "mod"

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
end
