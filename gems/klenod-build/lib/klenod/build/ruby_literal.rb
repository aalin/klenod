# frozen_string_literal: true

require "date"

module Klenod
  module Build
    # Writes parsed data as Ruby source for generated modules. Every hash,
    # array, time, and date is frozen; string literals are frozen because
    # modules are evaluated with `frozen_string_literal: true`.
    module RubyLiteral
      module_function

      # `inspect` is not Ruby source for every parsed value: dates, times,
      # and non-finite floats need constructor calls instead.
      def frozen(value)
        case value
        when Hash
          entries = value.map { |key, entry| "#{frozen(key)} => #{frozen(entry)}" }
          "{#{entries.join(", ")}}.freeze"
        when Array
          "[#{value.map { frozen(it) }.join(", ")}].freeze"
        when Float
          float(value)
        when Time
          zone = value.utc? ? "UTC" : value.utc_offset
          "::Time.at(#{value.to_i}, #{value.nsec}, :nsec, in: #{zone.inspect}).freeze"
        when Date
          "::Date.new(#{value.year}, #{value.month}, #{value.day}).freeze"
        when nil, true, false, String, Symbol, Integer
          value.inspect
        else
          raise TypeError, "Cannot write #{value.class} as Ruby literal source"
        end
      end

      def float(value)
        if value.nan?
          "::Float::NAN"
        elsif value.infinite?
          value.positive? ? "::Float::INFINITY" : "-::Float::INFINITY"
        else
          value.inspect
        end
      end
    end
  end
end
