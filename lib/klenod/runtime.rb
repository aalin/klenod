# frozen_string_literal: true

require_relative "source_map"
require_relative "runtime/mod"
require_relative "runtime/bundle"

module Klenod
  module Runtime
    def self.load_bundle(path, source_root: nil)
      Bundle.load_file(path, source_root: source_root)
    end
  end
end
