# frozen_string_literal: true

require "minitest/autorun"

require_relative "ruby_literal"

class Klenod::Build::RubyLiteral::Test < Minitest::Test
  def test_writes_frozen_hashes_and_arrays
    value = {
      "en-US" => {
        "title" => "Hello \#{name}",
        "items" => [1, 2]
      }
    }
    source = Klenod::Build::RubyLiteral.frozen(value)

    assert_equal('{"en-US" => {"title" => "Hello \\#{name}", "items" => [1, 2].freeze}.freeze}.freeze', source)

    evaluated = eval(source) # standard:disable Security/Eval
    assert_equal(value, evaluated)
    assert_predicate(evaluated, :frozen?)
    assert_predicate(evaluated.fetch("en-US").fetch("items"), :frozen?)
  end

  def test_writes_frozen_times_and_dates
    time = Time.at(1_700_000_000, 5, :nsec, in: "+02:00")
    date = Date.new(2026, 10, 9)
    evaluated = eval(Klenod::Build::RubyLiteral.frozen([time, date])) # standard:disable Security/Eval

    assert_equal([time, date], evaluated)
    assert_equal(time.utc_offset, evaluated.fetch(0).utc_offset)
    assert(evaluated.all?(&:frozen?))
  end

  def test_writes_non_finite_floats
    evaluated = eval(Klenod::Build::RubyLiteral.frozen([Float::INFINITY, -Float::INFINITY, Float::NAN])) # standard:disable Security/Eval

    assert_equal([Float::INFINITY, -Float::INFINITY], evaluated.first(2))
    assert_predicate(evaluated.last, :nan?)
  end

  def test_rejects_values_without_literal_source
    assert_raises(TypeError) { Klenod::Build::RubyLiteral.frozen(Object.new) }
  end
end
