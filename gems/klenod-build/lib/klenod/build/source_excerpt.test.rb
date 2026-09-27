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

  def test_location_includes_line_and_column
    assert_equal("app:/a.tsx:3:9", SourceExcerpt.location(module_id: "app:/a.tsx", line: 3, column: 9))
    assert_equal("app:/a.haml:3", SourceExcerpt.location(module_id: "app:/a.haml", line: 3))
  end

  def test_location_falls_back_to_the_module_then_to_the_line
    assert_equal("app:/a.png", SourceExcerpt.location(module_id: "app:/a.png", line: nil))
    assert_equal("line 3 column 9", SourceExcerpt.location(module_id: nil, line: 3, column: 9))
    assert_nil(SourceExcerpt.location(module_id: nil, line: nil))
  end

  def test_header_puts_kind_and_detail_on_one_line
    assert_equal("× JSON parse error: bad", SourceExcerpt.header("JSON parse error", "bad", ansi: false))
    assert_equal("× Parse error: one\n  two", SourceExcerpt.header("Parse error", "one\ntwo", ansi: false))
    assert_equal("× Parse error", SourceExcerpt.header("Parse error", "", ansi: false))
    assert_equal("\e[1;31m× Parse error:\e[0m \e[31mbad\e[0m", SourceExcerpt.header("Parse error", "bad"))
  end

  def test_excerpt_marks_the_line_and_windows_two_lines_either_side
    excerpt = SourceExcerpt.excerpt(source: SOURCE, line: 4, ansi: false)

    assert_equal(
      ["    ╭────", "  2 │ two", "  3 │ three", "> 4 │ four", "  5 │ five", "  6 │ six", "    ╰────"],
      excerpt.lines.map(&:chomp)
    )
  end

  def test_excerpt_aligns_a_caret_under_the_column
    excerpt = SourceExcerpt.excerpt(source: SOURCE, line: 3, column: 4, ansi: false)
    marked, caret = excerpt.lines.map(&:chomp).each_cons(2).find { |row, _| row.start_with?(">") }

    assert_equal("> 3 │ three", marked)
    assert_equal("    ·    ^", caret)
    # The caret sits under the character the column names.
    assert_equal("e", marked[caret.index("^")])
  end

  def test_excerpt_names_the_location_in_its_header
    excerpt = SourceExcerpt.excerpt(source: SOURCE, line: 3, ansi: false, location: "app:/a.txt:3")

    assert_equal("    ╭─[app:/a.txt:3]", excerpt.lines.first.chomp)
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

  def test_excerpt_dims_the_frame_and_the_other_line_numbers
    excerpt = SourceExcerpt.excerpt(source: SOURCE, line: 3, column: 2, location: "app:/a.txt:3")

    assert_includes(excerpt, "\e[2m╭─[\e[0mapp:/a.txt:3\e[2m]\e[0m")
    assert_includes(excerpt, "\e[2m  2 │\e[0m two")
    assert_includes(excerpt, "\e[1;31m> 3 │ three\e[0m")
    assert_includes(excerpt, "\e[2m·\e[0m  ^")
    assert_includes(excerpt, "\e[2m╰────\e[0m")
  end

  def test_strip_removes_colors_and_links
    linked = "\e[34m#{SourceExcerpt.file_link("app:/a.txt:3", path: "/a.txt", line: 3)}\e[0m"

    assert_equal("app:/a.txt:3", SourceExcerpt.strip(linked))
    assert_equal("ab", SourceExcerpt.strip("a\e]8;;file:///a\ab\e]8;;\a"))
  end

  def test_hint_section_prefixes_each_hint
    assert_nil(SourceExcerpt.hint_section([]))
    assert_nil(SourceExcerpt.hint_section([nil, ""]))
    assert_equal("hint: Did you mean hero.jpeg?", SourceExcerpt.hint_section(["Did you mean hero.jpeg?"], ansi: false))
    assert_equal("hint: one\nhint: two", SourceExcerpt.hint_section(["one", "two"], ansi: false))
  end

  def test_hint_section_colors_hints_for_the_terminal_only
    assert_equal("\e[1;36mhint:\e[0m \e[36mDid you mean hero.jpeg?\e[0m", SourceExcerpt.hint_section(["Did you mean hero.jpeg?"]))
    refute_includes(SourceExcerpt.hint_section(["Did you mean hero.jpeg?"], ansi: false), "\e[")
  end

  def test_detail_colors_each_line_for_the_terminal_only
    assert_equal("\e[31mbad\e[0m\n\n\e[31mtoken\e[0m", SourceExcerpt.detail("bad\n\ntoken"))
    assert_equal("bad\n\ntoken", SourceExcerpt.detail("bad\n\ntoken", ansi: false))
  end

  def test_message_puts_the_location_in_the_excerpt_and_indents_hints_under_it
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

    assert_equal(<<~TEXT.chomp, message)
      × JSON parse error: unexpected token

          ╭─[app:/a.json:3:4]
        1 │ one
        2 │ two
      > 3 │ three
          ·    ^
        4 │ four
        5 │ five
          ╰────
        hint: Did you mean a.yaml?
    TEXT
  end

  def test_message_without_an_excerpt_puts_the_location_under_the_header
    message = SourceExcerpt.message(
      module_id: "app:/a.png",
      line: nil,
      kind: "Image decode error",
      source: SOURCE,
      message: "bad header",
      hints: ["Is it a PNG?"],
      ansi: false
    )

    assert_equal("× Image decode error: bad header\n  at app:/a.png\n\n  hint: Is it a PNG?", message)
  end

  def test_file_link_wraps_text_in_an_osc_8_link_with_line_and_column
    assert_equal(
      "\e]8;;file:///src/a%20b/%23c.tsx#3:22\e\\app:/a.tsx:3:22\e]8;;\e\\",
      SourceExcerpt.file_link("app:/a.tsx:3:22", path: "/src/a b/#c.tsx", line: 3, column: 22)
    )
    assert_equal("\e]8;;file:///a.rb#3\e\\a\e]8;;\e\\", SourceExcerpt.file_link("a", path: "/a.rb", line: 3))
  end

  def test_bold_file_name_keeps_the_scheme_and_position_regular
    assert_equal("app:\e[1m/scripts/Thing.tsx\e[22m:3:22", SourceExcerpt.bold_file_name("app:/scripts/Thing.tsx:3:22", "app:/scripts/Thing.tsx"))
    assert_equal("gem:\e[1m//klenod-ui/Button.haml\e[22m", SourceExcerpt.bold_file_name("gem://klenod-ui/Button.haml", "gem://klenod-ui/Button.haml"))
  end

  def test_hyperlinks_are_on_only_in_terminals_known_to_support_them
    assert(SourceExcerpt.hyperlinks?({"TERM_PROGRAM" => "iTerm.app"}))
    assert(SourceExcerpt.hyperlinks?({"TERM" => "xterm-kitty"}))
    refute(SourceExcerpt.hyperlinks?({"TERM_PROGRAM" => "Apple_Terminal"}))
    refute(SourceExcerpt.hyperlinks?({"TERM_PROGRAM" => "iTerm.app", "NO_COLOR" => "1"}))
  end

  def test_message_links_the_location_to_an_existing_file
    linked = SourceExcerpt.message(module_id: "app:/a.txt", line: 3, kind: "Parse error", source: SOURCE, message: "bad", path: File.expand_path(__FILE__), links: true)
    plain = SourceExcerpt.message(module_id: "app:/a.txt", line: 3, kind: "Parse error", source: SOURCE, message: "bad", path: File.expand_path(__FILE__), links: false)
    missing = SourceExcerpt.message(module_id: "app:/a.txt", line: 3, kind: "Parse error", source: SOURCE, message: "bad", path: "#{__dir__}/missing.txt", links: true)

    assert_includes(linked, "\e[34m\e]8;;file://#{File.expand_path(__FILE__)}#3\e\\app:\e[1m/a.txt\e[22m:3\e]8;;\e\\\e[0m")
    refute_includes(plain, "\e]8")
    refute_includes(missing, "\e]8")
  end
end
