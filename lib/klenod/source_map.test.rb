# frozen_string_literal: true

require "minitest/autorun"

require_relative "source_map"

class Klenod::SourceMap::Test < Minitest::Test
  def test_old_constant_aliases_runtime_source_map
    assert_same(Klenod::Runtime::SourceMap, Klenod::SourceMap)
  end

  def test_mark_round_trips_through_comment_text
    mark = Klenod::Runtime::SourceMap::Mark.new(7, "hello")

    assert_equal(mark, Klenod::Runtime::SourceMap::Mark.parse(mark.to_s))
  end

  def test_maps_generated_lines_to_nearest_prior_mark
    source_map =
      Klenod::Runtime::SourceMap::SourceMap.parse(
        "one\ntwo\nthree\n",
        <<~RUBY
          class Example
            # #{Klenod::Runtime::SourceMap::Mark.new(2, "two")}
            def call
              :ok
            end
          end
        RUBY
      )

    assert_equal(2, source_map.find_original_line_no(4))
  end

  def test_later_marks_do_not_affect_earlier_generated_lines
    source_map =
      Klenod::Runtime::SourceMap::SourceMap.parse(
        "one\ntwo\nthree\n",
        <<~RUBY
          class Example
            # #{Klenod::Runtime::SourceMap::Mark.new(1, "one")}
            def first
              :ok
            end

            # #{Klenod::Runtime::SourceMap::Mark.new(3, "three")}
            def second
              :ok
            end
          end
        RUBY
      )

    assert_equal(1, source_map.find_original_line_no(4))
    assert_equal(3, source_map.find_original_line_no(9))
  end
end
