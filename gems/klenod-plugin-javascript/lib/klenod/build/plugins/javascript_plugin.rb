# frozen_string_literal: true

require "klenod/build/asset"
require "klenod/build/dependency"
require "klenod/build/errors"
require "klenod/build/hashing"
require "klenod/build/plugin"
require "klenod/build/source_map"
require "klenod/build/transform_result"
require "klenod/runtime"

require_relative "../../plugin/javascript/parser"

module Klenod
  module Build
    module Plugins
      module JavaScriptPlugin
        class Plugin < Klenod::Build::Plugin
          CONTENT_TYPE = "application/javascript"
          EXTENSIONS = [".js", ".ts"].freeze
          LOCAL_SPECIFIER_PATTERN = %r{\A(?:\.{1,2}/|/|app:/)}
          EXTERNAL_SPECIFIER_PATTERN = %r{\A(?:[A-Za-z][A-Za-z0-9+.-]*:)?//}
          VALID_SOURCE_MAP_MODES = [false, true, :development].freeze

          def initialize(source_maps: :development)
            unless VALID_SOURCE_MAP_MODES.include?(source_maps)
              raise ArgumentError, "source_maps must be false, true, or :development"
            end

            @source_maps = source_maps
          end

          def resolve(dependency, context)
            return nil unless dependency.kind.to_s.start_with?("javascript_")
            return nil unless extensionless_javascript_specifier?(dependency.specifier)

            extensionless_resolve_extensions(dependency).each do |extension|
              return context.resolve_dependency(dependency.with(specifier: "#{dependency.specifier}#{extension}"))
            rescue ResolveError
              next
            end

            nil
          end

          def transform(module_id, code, _context)
            return super unless EXTENSIONS.include?(module_id.extname)

            transform = Klenod::Plugin::JavaScript::Parser.transform(code, filename: module_id.to_s, source_kind: source_kind(module_id))
            dependencies = build_dependencies(module_id, transform.imports)

            TransformResult.new(
              module_source(nil),
              dependencies,
              nil,
              [],
              [],
              {
                javascript_source: transform.code,
                javascript_original_source: code,
                javascript_imports: transform.imports
              }
            )
          end

          def finalize(module_id, result, resolved_dependencies, dependency_records, context)
            source = result.metadata[:javascript_source]
            original_source = result.metadata[:javascript_original_source]
            imports = result.metadata[:javascript_imports]
            return result unless source && imports

            edit = rewrite_imports(module_id, source, original_source, imports, resolved_dependencies, dependency_records)
            source_map_asset = nil
            code = edit.code

            if source_maps_enabled?(context)
              source_map_json = edit.source_map.to_json
              source_map_hash = Hashing.short(source_map_json)
              source_map_output_path = "/assets/#{asset_name(module_id)}.#{source_map_hash}.js.map"
              source_map_asset =
                Asset.new(
                  module_id.path,
                  source_map_hash,
                  source_map_output_path,
                  nil,
                  source_map_json,
                  "application/json",
                  {type: :javascript_source_map}
                )
              code = "#{code.chomp}\n//# sourceMappingURL=#{File.basename(source_map_output_path)}\n"
            end

            hash = Hashing.short(code)
            output_path = "/assets/#{asset_name(module_id)}.#{hash}.js"
            asset =
              Asset.new(
                module_id.path,
                hash,
                output_path,
                nil,
                code,
                CONTENT_TYPE,
                {type: :javascript}
              )

            result.with(
              code: module_source(output_path),
              assets: [asset, source_map_asset].compact,
              metadata: result.metadata.merge(javascript_asset_path: output_path)
            )
          end

          def import_value(_resolved_dependency, record, context)
            return nil unless EXTENSIONS.include?(record.id.extname)

            context.mods.fetch(record.id).const_get(:Exports)::Default
          end

          def runtime_import_value(_resolved_dependency, record, _context)
            return nil unless EXTENSIONS.include?(record.id.extname)

            record.metadata.fetch(:javascript_asset_path)
          end

          private

          def build_dependencies(module_id, imports)
            imports.filter_map.with_index do |import, index|
              next if external_specifier?(import.specifier)
              raise DynamicImportError, unsupported_specifier_message(import) unless local_specifier?(import.specifier)

              Dependency
                .create(
                  specifier: import.specifier,
                  importer_id: module_id,
                  kind: import.kind,
                  loc: import.loc,
                  metadata: {start_offset: import.start_offset, end_offset: import.end_offset}
                )
                .with(id: "#{module_id}:dependency:#{index}")
            end
          end

          def rewrite_imports(module_id, source, original_source, imports, resolved_dependencies, dependency_records)
            resolved_by_range =
              resolved_dependencies.to_h do |resolved_dependency|
                metadata = resolved_dependency.dependency.metadata
                range = [metadata.fetch(:start_offset), metadata.fetch(:end_offset)]
                record = dependency_records.fetch(resolved_dependency.dependency.id)
                [range, record.metadata.fetch(:javascript_asset_path)]
              end

            edits =
              imports.filter_map do |import|
                replacement = resolved_by_range[[import.start_offset, import.end_offset]]
                next unless replacement

                SourceMap::Edit.replace(import.start_offset, import.end_offset, replacement)
              end

            SourceMap::Editor.new(source, identity_source_map(module_id, source, original_source)).apply(edits)
          end

          def identity_source_map(module_id, source, original_source)
            SourceMap::Map.new(
              version: 3,
              source_root: nil,
              sources: [module_id.path],
              sources_content: [original_source || source],
              names: [],
              segments: identity_segments(source)
            )
          end

          def identity_segments(source)
            line_count = source.count("\n") + 1
            line_count.times.map do |line|
              SourceMap::Segment.new(line, 0, 0, line, 0, nil)
            end
          end

          def source_maps_enabled?(context)
            case @source_maps
            when true
              true
            when :development
              context.mode == :development
            else
              false
            end
          end

          def unsupported_specifier_message(import)
            "Unsupported JavaScript import #{import.specifier.inspect} at #{import.loc}. Only relative, app-root, and external URL imports are supported."
          end

          def local_specifier?(specifier)
            specifier.match?(LOCAL_SPECIFIER_PATTERN)
          end

          def external_specifier?(specifier)
            specifier.match?(EXTERNAL_SPECIFIER_PATTERN)
          end

          def extensionless_javascript_specifier?(specifier)
            local_specifier?(specifier) && File.extname(specifier).empty?
          end

          def extensionless_resolve_extensions(dependency)
            return [".ts", ".js"] if dependency.importer_id&.extname == ".ts"

            [".js"]
          end

          def source_kind(module_id)
            return :typescript if module_id.extname == ".ts"

            :javascript
          end

          def module_source(output_path)
            <<~RUBY
              Default = #{output_path.inspect}
            RUBY
          end

          def asset_name(module_id)
            module_id.path.gsub(/[^A-Za-z0-9]+/, "_").sub(/\A_+/, "").sub(/_+\z/, "")
          end
        end
      end
    end
  end
end
