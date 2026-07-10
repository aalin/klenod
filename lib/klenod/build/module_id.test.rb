# frozen_string_literal: true

require "minitest/autorun"

require_relative "module_id"

class Klenod::Build::ModuleId::Test < Minitest::Test
  ModuleId = Klenod::Build::ModuleId

  def test_app_module_ids_default_to_app_scheme
    module_id = ModuleId.new("pages/page.rb", nil)

    assert_equal(:app, module_id.scheme)
    assert_equal("pages/page.rb", module_id.bare_path)
  end

  def test_scheme_is_inferred_from_prefixed_path
    module_id = ModuleId.new("virtual:router.rb", nil)

    assert_equal(:virtual, module_id.scheme)
    assert_equal("router.rb", module_id.bare_path)
  end

  def test_parse_preserves_query_and_scheme
    module_id = ModuleId.parse("virtual:klenod/image.rb?width=320")

    assert_equal(:virtual, module_id.scheme)
    assert_equal("klenod/image.rb", module_id.bare_path)
    assert_equal("width=320", module_id.query)
    assert_equal("virtual:klenod/image.rb?width=320", module_id.to_s)
  end
end
