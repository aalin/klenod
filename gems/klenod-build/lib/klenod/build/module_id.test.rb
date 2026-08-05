# frozen_string_literal: true

require "minitest/autorun"

require_relative "module_id"

class Klenod::Build::ModuleId::Test < Minitest::Test
  ModuleId = Klenod::Build::ModuleId

  def test_app_module_ids_default_to_app_scheme
    module_id = ModuleId.new("pages/page.rb", nil)

    assert_equal(:app, module_id.scheme)
    assert_equal("pages/page.rb", module_id.bare_path)
    assert_equal("app:/pages/page.rb", module_id.to_s)
  end

  def test_legacy_scheme_paths_are_normalized_to_hostless_uris
    module_id = ModuleId.new("virtual:router.rb", nil)

    assert_equal(:virtual, module_id.scheme)
    assert_equal("router.rb", module_id.bare_path)
    assert_equal("virtual:/router.rb", module_id.to_s)
  end

  def test_parse_preserves_query_and_scheme
    module_id = ModuleId.parse("virtual:klenod/image.rb?width=320")

    assert_equal(:virtual, module_id.scheme)
    assert_equal("klenod/image.rb", module_id.bare_path)
    assert_equal("width=320", module_id.query)
    assert_equal("virtual:/klenod/image.rb?width=320", module_id.to_s)
  end

  def test_parse_preserves_hostful_gem_uri
    module_id = ModuleId.parse("gem://klenod-ui/components/Button.haml")

    assert_equal(:gem, module_id.scheme)
    assert_equal("klenod-ui", module_id.host)
    assert_equal("/components/Button.haml", module_id.uri_path)
    assert_equal("gem://klenod-ui/components/Button.haml", module_id.to_s)
  end

  def test_merge_uses_uri_resolution_rules
    app_page = ModuleId.parse("app:/pages/foo/+page.haml")
    gem_component = ModuleId.parse("gem://klenod-ui/components/Button.haml")

    assert_equal("app:/pages/foo/Icon.haml", app_page.merge("./Icon.haml").to_s)
    assert_equal("app:/pages/foo/Card.haml", app_page.merge("Card.haml").to_s)
    assert_equal("app:/components/Hello.haml", app_page.merge("/components/Hello.haml").to_s)
    assert_equal("gem://klenod-ui/components/Icon.haml", gem_component.merge("./Icon.haml").to_s)
    assert_equal("gem://klenod-ui/components/Icon.haml", gem_component.merge("Icon.haml").to_s)
    assert_equal("gem://klenod-ui/tokens.css", gem_component.merge("/tokens.css").to_s)
    assert_equal("app:/components/Hello.haml", gem_component.merge("app:/components/Hello.haml").to_s)
  end

  def test_preserves_queries_when_constructing_and_merging
    app_page = ModuleId.parse("app:/pages/foo/+page.haml")

    assert_equal("app:/images/hero.jpg?width=320", ModuleId.new("images/hero.jpg?width=320", nil).to_s)
    assert_equal("app:/images/hero.jpg?width=640", ModuleId.new("images/hero.jpg?width=320", "width=640").to_s)
    assert_equal("app:/pages/foo/image.jpg?width=320", app_page.merge("./image.jpg?width=320").to_s)
    assert_equal("app:/pages/foo/+page.haml?inline=0", app_page.merge("?inline=0").to_s)
  end

  def test_preserves_route_syntax_paths
    page = ModuleId.parse("app:/routes/(marketing)/blog/[slug]/+page.haml")
    modal = ModuleId.parse("app:/routes/demo/@modal/(.)photo/+page.haml")

    assert_equal("app:/routes/(marketing)/blog/[slug]/article.md", page.merge("./article.md").to_s)
    assert_equal("app:/routes/demo/@modal/(.)photo/data.json", modal.merge("data.json").to_s)
  end
end
