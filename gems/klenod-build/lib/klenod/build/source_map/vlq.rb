# frozen_string_literal: true

module Klenod
  module Build
    module SourceMap
      module VLQ
        BASE64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        BASE64_VALUES = BASE64_CHARS.each_char.with_index.to_h.freeze
        CONTINUATION_BIT = 32
        VALUE_MASK = 31

        module_function

        def decode(segment)
          values = []
          value = 0
          shift = 0

          segment.each_char do |char|
            digit = BASE64_VALUES.fetch(char)
            continuation = (digit & CONTINUATION_BIT) != 0
            digit &= VALUE_MASK
            value += digit << shift

            if continuation
              shift += 5
            else
              values << from_vlq_signed(value)
              value = 0
              shift = 0
            end
          end

          values
        end

        def encode(values)
          values.map { encode_value(it) }.join
        end

        def encode_value(value)
          vlq = to_vlq_signed(value)
          encoded = +""

          loop do
            digit = vlq & VALUE_MASK
            vlq >>= 5
            digit |= CONTINUATION_BIT if vlq > 0
            encoded << BASE64_CHARS[digit]
            break if vlq == 0
          end

          encoded
        end

        def to_vlq_signed(value)
          (value < 0) ? ((-value) << 1) + 1 : value << 1
        end

        def from_vlq_signed(value)
          negative = (value & 1) == 1
          shifted = value >> 1
          negative ? -shifted : shifted
        end
      end
    end
  end
end
