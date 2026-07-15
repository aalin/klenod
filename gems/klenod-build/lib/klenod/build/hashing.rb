# frozen_string_literal: true

require "digest"

module Klenod
  module Build
    module Hashing
      def self.hexdigest(value)
        Digest::SHA256.hexdigest(value)
      end

      def self.file_hexdigest(path)
        Digest::SHA256.file(path.to_s).hexdigest
      end

      def self.short(value, length: 16)
        hexdigest(value)[0, length]
      end
    end
  end
end
