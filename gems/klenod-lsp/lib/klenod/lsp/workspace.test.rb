# frozen_string_literal: true

require_relative "__test__/support"

class Klenod::LSP::Workspace::Test < Minitest::Test
  include Klenod::LSP::TestSupport

  def setup
    @workspace = fixture_workspace
  end

  def test_maps_uris_inside_the_source_dir_to_app_module_ids
    assert_equal("app:/pages/Page.haml", @workspace.module_id_for_uri(fixture_uri("pages/Page.haml")).to_s)
    assert_equal("app:/pages/+page.haml", @workspace.module_id_for_uri(fixture_uri("pages/%2Bpage.haml")).to_s)
    assert_nil(@workspace.module_id_for_uri("file:///elsewhere/Page.haml"))
    assert_nil(@workspace.module_id_for_uri("untitled:Untitled-1"))
  end

  def test_maps_app_module_ids_back_to_file_uris
    uri = @workspace.uri_for_module_id(module_id("pages/Page.haml"))

    assert_equal(fixture_uri("pages/Page.haml"), uri)
    assert_nil(@workspace.uri_for_module_id(Klenod::Build::ModuleId.new("virtual:/router.rb")))
  end

  def test_percent_encodes_and_decodes_paths
    path = "#{Klenod::LSP::TestSupport::FIXTURE_SOURCE_DIR}/pages/my page+ä.haml"

    uri = @workspace.uri_for_path(path)

    assert_equal("file://#{Klenod::LSP::TestSupport::FIXTURE_SOURCE_DIR}/pages/my%20page+%C3%A4.haml", uri)
    assert_equal(path, @workspace.path_for_uri(uri))
  end

  def test_analyze_does_not_collect_or_evaluate
    analysis = @workspace.analyze(module_id("pages/Page.haml"), fixture_source("pages/Page.haml"))

    assert_nil(analysis.build_error)
    assert_empty(analysis.ruby_errors)
    assert_empty(analysis.resolve_errors)
    assert_equal("app:/components/Details.haml", analysis.resolved_module_id_for("/components/Details").to_s)
    assert_empty(@workspace.context.graph.records)
    assert_empty(@workspace.context.graph.mods)
  end

  def test_resolve_returns_nil_for_unknown_specifiers
    assert_equal("app:/pages/layout.rb", @workspace.resolve("./layout", importer_id: module_id("pages/Page.haml")).to_s)
    assert_nil(@workspace.resolve("./nope", importer_id: module_id("pages/Page.haml")))
  end
end
