# frozen_string_literal: true

require "minitest/autorun"

require "klenod/build/source_error"

class Klenod::Build::SourceError::Test < Minitest::Test
  SourceError = Klenod::Build::SourceError

  SOURCE = "alpha\nbravo\ncharlie\n"

  # A plugin that knows how to unpack its library's exception.
  class LocatedError < SourceError
    def kind
      "Example parse error"
    end

    private

    def location(error)
      Location.new(line: 2, column: 3, detail: "bad token", hints: ["Did you mean bravo?", ""])
    end
  end

  # A plugin whose library reports nothing useful.
  class BareError < SourceError
    def kind
      "Example decode error"
    end
  end

  def test_source_errors_are_collectable_by_the_build
    # A bare Ruby SyntaxError is a ScriptError and escapes every `rescue => e`
    # in the build, taking the watcher thread down with it.
    assert_operator(SourceError, :<, StandardError)
    assert_operator(SourceError, :<, Klenod::Build::Error)
  end

  def test_carries_the_structured_location_as_the_source_of_truth
    error = LocatedError.new(RuntimeError.new("raw"), source: SOURCE, module_id: "app:/a.ex")

    assert_equal("app:/a.ex", error.module_id)
    assert_equal(SOURCE, error.source)
    assert_equal(2, error.line)
    assert_equal(3, error.column)
    assert_equal("bad token", error.detail)
    assert_equal(["Did you mean bravo?"], error.hints)
    assert_equal("Example parse error", error.kind)
  end

  def test_renders_title_detail_excerpt_and_hint_into_the_message
    error = LocatedError.new(RuntimeError.new("raw"), source: SOURCE, module_id: "app:/a.ex")

    assert_includes(error.message, "app:/a.ex:2:3: Example parse error")
    assert_includes(error.message, "bad token")
    assert_includes(error.message, "> 2 | bravo")
    assert_includes(error.message, "Hint:\n  Did you mean bravo?")
  end

  def test_backtrace_points_at_the_module
    error = LocatedError.new(RuntimeError.new("raw"), source: SOURCE, module_id: "app:/a.ex")

    # The browser dialog highlights source lines by matching backtrace frames
    # against the filename.
    assert_equal("app:/a.ex:2:3", error.backtrace.fetch(0))
  end

  def test_without_a_location_it_keeps_the_wrapped_message_and_renders_no_excerpt
    cause = RuntimeError.new("something went wrong")
    error = BareError.new(cause, source: SOURCE, module_id: "app:/a.png")

    assert_nil(error.line)
    assert_nil(error.column)
    assert_empty(error.hints)
    assert_equal("something went wrong", error.detail)
    assert_same(cause, error.cause)
    assert_equal(SOURCE, error.source)
    assert_equal("app:/a.png: Example decode error\n\nsomething went wrong", error.message)
    refute_includes(error.message, "Source:")
  end

  def test_a_subclass_that_declares_nothing_still_reports_the_file
    error = SourceError.new(RuntimeError.new("boom"), source: SOURCE, module_id: "app:/a.ex")

    assert_equal("app:/a.ex: Parse error\n\nboom", error.message)
  end
end
