# frozen_string_literal: true

require_relative "__test__/support"

class Klenod::LSP::Renames::Test < Minitest::Test
  include Klenod::LSP::TestSupport

  def setup
    @workspace = fixture_workspace
    @index = fixture_index(@workspace, module_id("entry.rb"), module_id("pages/Page.haml"), module_id("pages/page_spec.rb"), module_id("pages/lazy.rb"))
  end

  def test_renaming_a_file_rewrites_every_importer_and_keeps_literal_styles
    edits = rename("components/Details.haml", "components/Card.haml")

    assert_equal({fixture_uri("entry.rb") => ["/components/Card.haml"], fixture_uri("pages/Page.haml") => ["/components/Card"]}, edits)
  end

  def test_moving_a_file_rewrites_relative_and_bare_importers
    edits = rename("pages/layout.rb", "layouts/main.rb")

    assert_equal({fixture_uri("entry.rb") => ["layouts/main"], fixture_uri("pages/Page.haml") => ["../layouts/main"]}, edits)
  end

  def test_moving_a_module_rewrites_its_own_relative_imports_and_its_importers
    edits = rename("pages/Page.haml", "views/Page.haml")

    assert_equal(
      {
        fixture_uri("entry.rb") => ["/views/Page.haml"],
        fixture_uri("pages/Page.haml") => ["../pages/layout"],
        fixture_uri("pages/page_spec.rb") => ["../views/Page.haml"]
      },
      edits
    )
  end

  def test_renaming_a_folder_leaves_imports_inside_it_alone
    edits = rename("pages", "views")

    assert_equal({fixture_uri("entry.rb") => ["/views/Page.haml", "views/layout"]}, edits)
  end

  def test_unrelated_or_external_renames_produce_no_edit
    assert_nil(Klenod::LSP::Renames.call([["file:///elsewhere/a.rb", "file:///elsewhere/b.rb"]], @index, @workspace))
    assert_nil(rename_raw("pages/BrokenIntl.haml", "pages/Broken.haml"))
  end

  def test_lazy_importers_are_rewritten_too
    assert_equal({fixture_uri("pages/lazy.rb") => ["./Lazy.haml"]}, rename("pages/LazyPage.haml", "pages/Lazy.haml"))
  end

  def test_query_strings_survive_rewrites
    assert_equal("/images/photo.png?width=320", Klenod::LSP::Renames.rewrite_specifier("/images/hero.png?width=320", "#{@workspace.source_dir}/pages/Page.haml", "#{@workspace.source_dir}/images/photo.png", @workspace.source_dir))
    assert_equal("./photo.png", Klenod::LSP::Renames.rewrite_specifier("./hero.png", "#{@workspace.source_dir}/pages/Page.haml", "#{@workspace.source_dir}/pages/photo.png", @workspace.source_dir))
  end

  private

  def rename_raw(old_relative, new_relative)
    Klenod::LSP::Renames.call([[fixture_uri(old_relative), fixture_uri(new_relative)]], @index, @workspace)
  end

  def rename(old_relative, new_relative)
    edit = rename_raw(old_relative, new_relative)
    edit.changes.transform_values { |edits| edits.map(&:new_text) }
  end
end
