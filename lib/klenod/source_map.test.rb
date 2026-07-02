# frozen_string_literal: true

require "minitest/autorun"

require_relative "source_map"

class Klenod::SourceMap::Test < Minitest::Test
  def test_mark_round_trips_through_comment_text
    mark = Klenod::SourceMap::Mark.new(7, "hello")

    assert_equal(mark, Klenod::SourceMap::Mark.parse(mark.to_s))
  end

  def test_maps_generated_lines_to_nearest_prior_mark
    source_map =
      Klenod::SourceMap::SourceMap.parse(
        "one\ntwo\nthree\n",
        <<~RUBY
          class Example
            # #{Klenod::SourceMap::Mark.new(2, "two")}
            def call
              :ok
            end
          end
        RUBY
      )

    assert_equal(2, source_map.find_original_line_no(4))
  end
end
