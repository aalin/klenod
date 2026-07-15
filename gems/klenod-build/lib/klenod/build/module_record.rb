# frozen_string_literal: true

module Klenod
  module Build
    ModuleRecord =
      Data.define(
        :id,
        :source_hash,
        :transformed_hash,
        :dependencies,
        :resolved_dependencies,
        :source,
        :transformed_source,
        :source_map,
        :assets,
        :watched_patterns,
        :metadata,
        :version,
        :status
      )
  end
end
