# frozen_string_literal: true

require "json"
require "minitest/autorun"

require_relative "editor"

class Klenod::Build::SourceMap::EditorTest < Minitest::Test
  SourceMap = Klenod::Build::SourceMap

  def test_applies_replacement_and_shifts_generated_mappings
    map =
      SourceMap::Map.new(
        version: 3,
        source_root: nil,
        sources: ["input.css"],
        sources_content: [".a {}\n.b {}\n"],
        names: [],
        segments: [
          SourceMap::Segment.new(0, 0, 0, 0, 0, nil),
          SourceMap::Segment.new(1, 0, 0, 1, 0, nil)
        ]
      )

    result =
      SourceMap::Editor
        .new("xx\n.a {}\n", map)
        .apply([SourceMap::Edit.replace(0, 2, "longer")])

    assert_equal("longer\n.a {}\n", result.code)
    assert_equal([0, 1], result.source_map.segments.map(&:generated_line))
    assert_equal([0, 0], result.source_map.segments.map(&:generated_column))
  end

  def test_deletes_mapped_line_and_shifts_later_mappings
    map =
      SourceMap::Map.new(
        version: 3,
        source_root: nil,
        sources: ["input.css"],
        sources_content: ["@import \"\";\n.a {}\n"],
        names: [],
        segments: [
          SourceMap::Segment.new(0, 0, 0, 0, 0, nil),
          SourceMap::Segment.new(1, 0, 0, 1, 0, nil)
        ]
      )

    result =
      SourceMap::Editor
        .new("@import \"\";\n.a {}\n", map)
        .apply([SourceMap::Edit.delete(0, 12)])

    assert_equal(".a {}\n", result.code)
    assert_equal([[0, 0, 1]], result.source_map.segments.map { |segment| [segment.generated_line, segment.generated_column, segment.original_line] })
  end

  def test_source_map_json_round_trips_mappings
    source_map =
      SourceMap::Map.parse(
        JSON.generate(
          "version" => 3,
          "mappings" => "AAAA;AACA",
          "sources" => ["input.css"],
          "sourcesContent" => [".a {}\n.b {}\n"],
          "names" => []
        )
      )

    assert_equal("AAAA;AACA", SourceMap::Map.parse(source_map.to_json).encode_mappings)
  end
end
