# frozen_string_literal: true

require_relative "../errors"
require_relative "../module_id"
require_relative "../plugin"

module Klenod
  module Build
    module Plugins
      module TestPlugin
        def self.new(...)
          Plugin.new(...)
        end

        class Plugin < Klenod::Build::Plugin
          DEFAULT_PATTERN = "**/*.test.rb"

          def initialize(pattern: DEFAULT_PATTERN)
            @pattern = pattern.to_s
          end

          attr_reader :pattern

          def discover(source_dir:)
            root = Pathname.new(source_dir).expand_path

            root
              .glob(pattern)
              .select(&:file?)
              .map { |path| ModuleId.new(path.relative_path_from(root).to_s.tr("\\", "/"), nil) }
              .sort_by(&:to_s)
          end

          def test_module_id?(module_id)
            module_id.scheme == :app && File.fnmatch?(pattern, module_id.relative_path, File::FNM_PATHNAME | File::FNM_EXTGLOB)
          end

          def finalize(module_id, result, resolved_dependencies, _dependency_records, _context)
            imported_test = resolved_dependencies.find { |dependency| test_module_id?(dependency.module_id) }
            return result unless imported_test

            error = TestImportError.new("Test file #{imported_test.module_id.path.inspect} cannot be imported")
            raise error.with_resolution_context(dependency: imported_test.dependency, importer_id: module_id)
          end
        end
      end
    end
  end
end
