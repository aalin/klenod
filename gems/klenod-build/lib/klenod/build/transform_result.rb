# frozen_string_literal: true

module Klenod
  module Build
    TransformResult =
      Data.define(:code, :dependencies, :source_map, :assets, :watched_patterns, :metadata) do
        def self.identity(code)
          new(code, [], nil, [], [], {})
        end
      end
  end
end
