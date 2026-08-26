# frozen_string_literal: true

require_relative "../dependency"
require_relative "../errors"
require_relative "../filesystem_resolver"
require_relative "../hashing"
require_relative "../load_result"
require_relative "../module_id"
require_relative "../plugin"

module Klenod
  module Build
    module Plugins
      module GemImportPlugin
        class Plugin < Klenod::Build::Plugin
          DEFAULT_IMPORT_ROOT = "klenod"
          DEFAULT_EXTENSIONS = [".rb", ".haml"].freeze

          def initialize(import_root: DEFAULT_IMPORT_ROOT, extensions: DEFAULT_EXTENSIONS)
            @import_root = import_root.to_s.delete_prefix("/")
            @extensions = extensions
            @resolved_paths = {}
            @gem_import_roots = {}
            @filesystem_resolvers = {}
          end

          def resolve(dependency, _context)
            module_id = module_id_for(dependency)
            return nil unless module_id&.scheme == :gem

            resolved_path = resolve_existing_path(module_id)
            resolved_id = module_id_for_path(module_id, resolved_path)
            ResolvedDependency.new(dependency, resolved_id, {scheme: :gem, path: resolved_path.to_s})
          rescue ResolveError => error
            raise error.with_resolution_context(dependency: dependency, importer_id: dependency.importer_id)
          end

          def load(module_id, _context)
            return nil unless module_id.scheme == :gem

            path = path_for(module_id)
            LoadResult.new(path.binread, Hashing.file_hexdigest(path), nil)
          end

          private

          def module_id_for(dependency)
            specifier = dependency.specifier.to_s
            if specifier.match?(ModuleId::SCHEME_PATTERN)
              module_id = ModuleId.parse(specifier)
              return nil unless module_id.scheme == :gem

              module_id
            elsif dependency.importer_id&.scheme == :gem
              dependency.importer_id.merge(specifier)
            end
          end

          def resolve_existing_path(module_id)
            @resolved_paths.fetch([module_id.to_s, module_id.query]) do |key|
              path_for(module_id)
              resolved = filesystem_resolver_for(module_id).resolve(module_id.relative_path)
              @resolved_paths[key] = resolved
            end
          rescue ResolveError => error
            raise ResolveError.new(
              error.resolution_failure? ? nil : error.message,
              unresolved_path: module_id.to_s,
              reason: error.reason,
              requested_specifier: error.requested_specifier,
              suggestions: error.suggestions
            )
          end

          def path_for(module_id)
            raise ResolveError, "Gem import requires a gem name in #{module_id}" if module_id.host.to_s.empty?

            import_root = import_root_for(module_id.host)
            path = Pathname.new(File.expand_path(module_id.relative_path, import_root))
            assert_inside_import_root!(module_id, import_root, path)
            path
          end

          def import_root_for(gem_name)
            @gem_import_roots.fetch(gem_name) do
              spec = Gem::Specification.find_by_name(gem_name)
              @gem_import_roots[gem_name] = Pathname.new(File.expand_path(@import_root, spec.full_gem_path))
            end
          rescue Gem::LoadError => error
            raise ResolveError, "Could not find gem #{gem_name.inspect}: #{error.message}"
          end

          def filesystem_resolver_for(module_id)
            @filesystem_resolvers.fetch(module_id.host) do |gem_name|
              @filesystem_resolvers[gem_name] =
                FilesystemResolver.new(
                  root: import_root_for(gem_name),
                  extensions: @extensions,
                  path_prefix: "gem://#{gem_name}/"
                )
            end
          end

          def assert_inside_import_root!(module_id, import_root, path)
            import_root_path = import_root.to_s
            expanded = path.to_s
            return if expanded == import_root_path || expanded.start_with?("#{import_root_path}/")

            raise ResolveError, "Gem import escapes import root: #{module_id}"
          end

          def module_id_for_path(module_id, path)
            import_root = import_root_for(module_id.host)
            relative = path.relative_path_from(import_root).to_s
            ModuleId.new("gem://#{module_id.host}/#{relative}", module_id.query)
          end
        end
      end
    end
  end
end
