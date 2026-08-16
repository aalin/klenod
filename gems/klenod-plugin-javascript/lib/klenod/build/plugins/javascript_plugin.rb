# frozen_string_literal: true

require "klenod/build/asset"
require "klenod/build/dependency"
require "klenod/build/errors"
require "klenod/build/hashing"
require "klenod/build/plugin"
require "klenod/build/transform_result"
require "klenod/runtime"

require_relative "../../plugin/javascript/parser"

module Klenod
  module Build
    module Plugins
      module JavaScriptPlugin
        class Plugin < Klenod::Build::Plugin
          CONTENT_TYPE = "application/javascript"
          EXTENSIONS = [".js"].freeze
          LOCAL_SPECIFIER_PATTERN = %r{\A(?:\.{1,2}/|/|app:/)}
          EXTERNAL_SPECIFIER_PATTERN = %r{\A(?:[A-Za-z][A-Za-z0-9+.-]*:)?//}

          def resolve(dependency, context)
            return nil unless dependency.kind.to_s.start_with?("javascript_")
            return nil unless extensionless_javascript_specifier?(dependency.specifier)

            context.resolve_dependency(dependency.with(specifier: "#{dependency.specifier}.js"))
          end

          def transform(module_id, code, _context)
            return super unless EXTENSIONS.include?(module_id.extname)

            imports = Klenod::Plugin::JavaScript::Parser.parse(code, filename: module_id.to_s)
            dependencies = build_dependencies(module_id, imports)

            TransformResult.new(
              module_source(nil),
              dependencies,
              nil,
              [],
              [],
              {javascript_source: code, javascript_imports: imports}
            )
          end

          def finalize(module_id, result, resolved_dependencies, dependency_records, _context)
            source = result.metadata[:javascript_source]
            imports = result.metadata[:javascript_imports]
            return result unless source && imports

            code = rewrite_imports(source, imports, resolved_dependencies, dependency_records)
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
              assets: [asset],
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

          def rewrite_imports(source, imports, resolved_dependencies, dependency_records)
            resolved_by_range =
              resolved_dependencies.to_h do |resolved_dependency|
                metadata = resolved_dependency.dependency.metadata
                range = [metadata.fetch(:start_offset), metadata.fetch(:end_offset)]
                record = dependency_records.fetch(resolved_dependency.dependency.id)
                [range, record.metadata.fetch(:javascript_asset_path)]
              end

            output = +""
            cursor = 0

            imports.each do |import|
              replacement = resolved_by_range[[import.start_offset, import.end_offset]]
              next unless replacement

              output << source.byteslice(cursor, import.start_offset - cursor)
              output << replacement
              cursor = import.end_offset
            end

            output << source.byteslice(cursor, source.bytesize - cursor)
            output
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
