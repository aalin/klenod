# frozen_string_literal: true

require "minitest/autorun"

require_relative "vlq"

class Klenod::Build::SourceMap::VLQTest < Minitest::Test
  VLQ = Klenod::Build::SourceMap::VLQ

  def test_round_trips_signed_values
    values = [-123, -1, 0, 1, 16, 123, 4096]

    assert_equal(values, VLQ.decode(VLQ.encode(values)))
  end
end
