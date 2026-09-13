# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require_relative "../../__test__/support"

class Klenod::LSP::Languages::Haml::Props::Test < Minitest::Test
  include Klenod::LSP::TestSupport

  def setup
    @workspace = fixture_workspace
    @index = fixture_index(@workspace)
    @language = Klenod::LSP::Languages::Haml.new
    @page_id = module_id("pages/Page.haml")
    @page_source = fixture_source("pages/Page.haml")
  end

  def test_known_props_and_implicit_children_pass
    assert_empty(prop_diagnostics(@page_source))
    assert_empty(prop_diagnostics(@page_source.sub("%Details{ summary: \"More\" }", "%Details(summary=\"More\"){ children: nil, \"summary\" => 1 }")))
  end

  def test_unknown_props_warn_with_suggestions_for_both_attribute_syntaxes
    source = @page_source.sub("%Details{ summary: \"More\" }", "%Details.card(sumary=\"More\" title=\"x\"){ waz: 1, :summry => 2 }")

    diagnostics = prop_diagnostics(source)

    assert_equal(
      [
        "Unknown prop \"sumary\" for Details; did you mean \"summary\"?",
        "Unknown prop \"title\" for Details",
        "Unknown prop \"waz\" for Details",
        "Unknown prop \"summry\" for Details; did you mean \"summary\"?"
      ],
      diagnostics.map(&:message)
    )
    assert_equal([2] * 4, diagnostics.map(&:severity))
    assert_equal("sumary", source.lines[5][diagnostics.fetch(0).range.start.character...diagnostics.fetch(0).range.end.character])
    assert_equal("summry", source.lines[5][diagnostics.fetch(3).range.start.character...diagnostics.fetch(3).range.end.character])
  end

  def test_bare_boolean_attributes_are_checked_too
    source = @page_source.sub("%Details{ summary: \"More\" }", "%Details(summary closed href=foo)")

    diagnostics = prop_diagnostics(source)

    assert_equal(["Unknown prop \"closed\" for Details", "Unknown prop \"href\" for Details"], diagnostics.map(&:message))
    assert_equal("closed", source.lines[5][diagnostics.fetch(0).range.start.character...diagnostics.fetch(0).range.end.character])
    assert_empty(prop_diagnostics(@page_source.sub("%Details{ summary: \"More\" }", "%Details(summary)")))
  end

  def test_splats_unknown_components_and_ruby_targets_are_not_checked
    assert_empty(prop_diagnostics(@page_source.sub("%Details{ summary: \"More\" }", "%Details{ nope: 1, **extra }")))
    assert_empty(prop_diagnostics(@page_source.sub("%Layout\n", "%Layout{ nope: 1 }\n")), "Ruby modules declare no props")
    assert_empty(prop_diagnostics(@page_source.sub("%Layout\n", "%Unknown{ nope: 1 }\n")))
  end

  def test_components_reading_every_prop_or_none_are_not_checked
    Dir.mktmpdir do |dir|
      FileUtils.cp_r("#{Klenod::LSP::TestSupport::FIXTURE_SOURCE_DIR}/.", dir)
      File.write("#{dir}/components/Passthrough.haml", "%div{ **$* }\n")
      File.write("#{dir}/components/Static.haml", "%hr\n")
      workspace = fixture_workspace(source_dir: dir)
      index = fixture_index(workspace)
      source = ":ruby\n  Passthrough = import(\"/components/Passthrough\")\n  Static = import(\"/components/Static\")\n\n%Passthrough{ anything: 1 }\n%Static{ anything: 1 }\n"

      assert_empty(@language.diagnostics(workspace.analyze(@page_id, source), workspace, index))
    end
  end

  private

  def prop_diagnostics(source)
    @language.diagnostics(@workspace.analyze(@page_id, source), @workspace, @index).select { |diagnostic| diagnostic.message.start_with?("Unknown prop") }
  end
end
