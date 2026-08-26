# frozen_string_literal: true

module Klenod
  module Build
    SourceLocation =
      Data.define(:path, :line, :column) do
        def to_s
          [path, line, column].compact.join(":")
        end
      end

    Dependency =
      Data.define(:id, :specifier, :importer_id, :kind, :loc, :metadata, :eager) do
        def self.create(specifier:, importer_id:, kind:, loc: nil, metadata: {})
          new(nil, specifier, importer_id, kind, loc, metadata.freeze, true)
        end
      end

    ResolvedDependency = Data.define(:dependency, :module_id, :metadata)
  end
end
