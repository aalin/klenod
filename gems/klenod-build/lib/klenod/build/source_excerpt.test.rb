# frozen_string_literal: true

require "minitest/autorun"

require "klenod/build/source_excerpt"

class Klenod::Build::SourceExcerpt::Test < Minitest::Test
  SourceExcerpt = Klenod::Build::SourceExcerpt

  SOURCE = <<~TEXT
    one
    two
    three
    four
    five
    six
  TEXT

  def test_title_includes_line_and_column
    assert_equal(
      "app:/a.tsx:3:9: JavaScript parse error",
      SourceExcerpt.title(module_id: "app:/a.tsx", line: 3, column: 9, kind: "JavaScript parse error")
    )
  end

  def test_title_omits_the_column_when_the_parser_does_not_report_one
    assert_equal(
      "app:/a.haml:3: Haml parse error",
      SourceExcerpt.title(module_id: "app:/a.haml", line: 3, kind: "Haml parse error")
    )
  end

  def test_title_falls_back_to_the_module_then_to_the_kind_alone
    assert_equal("app:/a.png: Image decode error", SourceExcerpt.title(module_id: "app:/a.png", line: nil, kind: "Image decode error"))
    assert_equal("line 3 column 9", SourceExcerpt.title(module_id: nil, line: 3, column: 9, kind: "x").delete_suffix(": x"))
    assert_equal("Parse error", SourceExcerpt.title(module_id: nil, line: nil, kind: "Parse error"))
  end

  def test_excerpt_marks_the_line_and_windows_two_lines_either_side
    excerpt = SourceExcerpt.excerpt(source: SOURCE, line: 4, ansi: false)

    assert_equal(
      ["Source:", "  2 | two", "  3 | three", "> 4 | four", "  5 | five", "  6 | six"],
      excerpt.lines.map(&:chomp)
    )
  end

  def test_excerpt_aligns_a_caret_under_the_column
    excerpt = SourceExcerpt.excerpt(source: SOURCE, line: 3, column: 4, ansi: false)
    marked, caret = excerpt.lines.map(&:chomp).each_cons(2).find { |row, _| row.start_with?(">") }

    assert_equal("> 3 | three", marked)
    assert_equal("    |    ^", caret)
    # The caret sits under the character the column names.
    assert_equal("e", marked[caret.index("^")])
  end

  def test_excerpt_omits_the_caret_without_a_column
    excerpt = SourceExcerpt.excerpt(source: SOURCE, line: 3, ansi: false)

    refute_includes(excerpt, "^")
  end

  def test_excerpt_returns_nil_when_there_is_nothing_to_point_at
    assert_nil(SourceExcerpt.excerpt(source: SOURCE, line: nil))
    assert_nil(SourceExcerpt.excerpt(source: "", line: 1))
    assert_nil(SourceExcerpt.excerpt(source: SOURCE, line: 99))
  end

  def test_excerpt_highlights_the_marked_line_for_the_terminal_only
    assert_includes(SourceExcerpt.excerpt(source: SOURCE, line: 3), "\e[1;31m")
    refute_includes(SourceExcerpt.excerpt(source: SOURCE, line: 3, ansi: false), "\e[")
  end

  def test_hint_section_pluralises_and_indents
    assert_nil(SourceExcerpt.hint_section([]))
    assert_nil(SourceExcerpt.hint_section([nil, ""]))
    assert_equal("Hint:\n  Did you mean hero.jpeg?", SourceExcerpt.hint_section(["Did you mean hero.jpeg?"]))
    assert_equal("Hints:\n  one\n  two", SourceExcerpt.hint_section(["one", "two"]))
  end

  def test_message_orders_title_detail_source_then_hint
    message = SourceExcerpt.message(
      module_id: "app:/a.json",
      line: 3,
      column: 4,
      kind: "JSON parse error",
      source: SOURCE,
      message: "unexpected token",
      hints: ["Did you mean a.yaml?"],
      ansi: false
    )

    assert_equal(
      ["app:/a.json:3:4: JSON parse error", "unexpected token", "Source:", "Hint:"],
      message.split("\n\n").map { it.lines.first.chomp }
    )
  end
end
