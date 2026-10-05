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

  def test_key_and_slot_are_accepted_by_every_component
    assert_empty(prop_diagnostics(@page_source.sub("%Details{ summary: \"More\" }", "%Details(slot=\"aside\" key=1){ summary: \"More\", key: 2, slot: :aside }")))
  end

  def test_attributes_continuing_on_the_next_lines_are_not_checked
    source = @page_source.sub("%Details{ summary: \"More\" }", "%Details(summary=\"Show source\"\n    nope=\"x\")")

    assert_empty(prop_diagnostics(source))
  end

  def test_dashed_keys_match_underscored_props
    Dir.mktmpdir do |dir|
      FileUtils.cp_r("#{Klenod::LSP::TestSupport::FIXTURE_SOURCE_DIR}/.", dir)
      File.write("#{dir}/components/Video.haml", "%iframe{ src: $video_id }\n")
      workspace = fixture_workspace(source_dir: dir)
      index = fixture_index(workspace)
      source = ":ruby\n  Video = import(\"/components/Video\")\n\n%Video(video-id=\"a\"){ \"video-id\" => \"b\", video_id: \"c\" }\n%Video(vidoe-id=\"a\")\n"

      diagnostics = @language.diagnostics(workspace.analyze(@page_id, source), workspace, index)

      assert_equal(["Unknown prop `vidoe-id` for `Video`; did you mean `video_id`?"], diagnostics.map(&:message))
    end
  end

  def test_unknown_props_warn_with_suggestions_for_both_attribute_syntaxes
    source = @page_source.sub("%Details{ summary: \"More\" }", "%Details.card(sumary=\"More\" title=\"x\"){ waz: 1, :summry => 2 }")

    diagnostics = prop_diagnostics(source)

    assert_equal(
      [
        "Unknown prop `sumary` for `Details`; did you mean `summary`?",
        "Unknown prop `title` for `Details`",
        "Unknown prop `waz` for `Details`",
        "Unknown prop `summry` for `Details`; did you mean `summary`?"
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

    assert_equal(["Unknown prop `closed` for `Details`", "Unknown prop `href` for `Details`"], diagnostics.map(&:message))
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

  def test_component_props_only_include_executable_ruby
    source = <<~HAML
      :ruby
        # %Example(id=$ruby_comment)
        value = $filter_prop # $trailing_comment
        hash = "\#{$interpolated_prop} # $in_string"

      -# $commented
      %p Price is $plain_text
      %div{ title: $attribute_prop }
        = $printed_prop # $printed_comment
    HAML

    props = Klenod::LSP::Languages::Imports.component_props(source, @workspace)

    assert_equal(%w[attribute_prop filter_prop in_string interpolated_prop printed_prop], props.names)
  end

  def test_component_props_include_attributes_continuing_on_the_next_lines
    source = <<~HAML
      %iframe(allowfullscreen class=$class){
        title: $title || "Player",
        src: "https://example.com/\#{$video_id}",
      }
      %div(id=$id
        data-x=$data_x) $after_attributes
    HAML

    props = Klenod::LSP::Languages::Imports.component_props(source, @workspace)

    assert_equal(%w[class data_x id title video_id], props.names)
  end

  def test_component_props_include_attributes_of_implicit_divs
    source = <<~HAML
      .switcher(class=$class)
        #menu.popover{
          class: $popover_class
        }= $content
    HAML

    props = Klenod::LSP::Languages::Imports.component_props(source, @workspace)

    assert_equal(%w[class content popover_class], props.names)
  end

  private

  def prop_diagnostics(source)
    @language.diagnostics(@workspace.analyze(@page_id, source), @workspace, @index).select { |diagnostic| diagnostic.message.start_with?("Unknown prop") }
  end
end
