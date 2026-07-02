# frozen_string_literal: true

require_relative "runtime/mod"
require_relative "runtime/bundle"

module Klenod
  module Runtime
    def self.load_bundle(path)
      Bundle.load_file(path)
    end
  end
end
