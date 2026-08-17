# frozen_string_literal: true

require "klenod/build/asset"
require "klenod/build/dependency"
require "klenod/build/errors"
require "klenod/build/hashing"
require "klenod/build/load_result"
require "klenod/build/module_id"
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
          EXTENSIONS = [".js", ".jsx", ".ts", ".tsx"].freeze
          CUSTOM_ELEMENT_EXTENSIONS = [".jsx", ".tsx"].freeze
          JSX_RUNTIME_SPECIFIER = "virtual:klenod/jsx-runtime"
          JSX_RUNTIME_MODULE_ID = ModuleId.new("virtual:klenod/jsx-runtime.js", nil)
          LOCAL_SPECIFIER_PATTERN = %r{\A(?:\.{1,2}/|/|app:/)}
          EXTERNAL_SPECIFIER_PATTERN = %r{\A(?:[A-Za-z][A-Za-z0-9+.-]*:)?//}
          VALID_SOURCE_MAP_MODES = [false, true, :development].freeze
          IDENTIFIER_PATTERN = '[$_\p{Alpha}][$\u200c\u200d\p{Alnum}_]*'
          DEFAULT_EXPORT_CLASS_PATTERN = /\bexport\s+default\s+class\s+(#{IDENTIFIER_PATTERN})\b/
          DEFAULT_EXPORT_IDENTIFIER_PATTERN = /\bexport\s+default\s+(#{IDENTIFIER_PATTERN})\s*;/

          def initialize(source_maps: :development)
            unless VALID_SOURCE_MAP_MODES.include?(source_maps)
              raise ArgumentError, "source_maps must be false, true, or :development"
            end

            @source_maps = source_maps
          end

          def resolve(dependency, context)
            return ResolvedDependency.new(dependency, JSX_RUNTIME_MODULE_ID, {virtual: true}) if dependency.specifier == JSX_RUNTIME_SPECIFIER
            return nil unless dependency.kind.to_s.start_with?("javascript_")
            return nil unless extensionless_javascript_specifier?(dependency.specifier)

            extensionless_resolve_extensions(dependency).each do |extension|
              return context.resolve_dependency(dependency.with(specifier: "#{dependency.specifier}#{extension}"))
            rescue ResolveError
              next
            end

            nil
          end

          def load(module_id, _context)
            return nil unless module_id.scheme == :virtual && module_id == JSX_RUNTIME_MODULE_ID

            LoadResult.new(jsx_runtime_source, nil, nil)
          end

          def transform(module_id, code, _context)
            return super unless EXTENSIONS.include?(module_id.extname)

            custom_element = custom_element_module?(module_id)
            source = custom_element ? jsx_module_source(code) : code
            transform = Klenod::Plugin::JavaScript::Parser.transform(source, filename: module_id.to_s, source_kind: source_kind(module_id))
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
                javascript_imports: transform.imports,
                javascript_custom_element: custom_element,
                javascript_custom_element_tag: custom_element ? custom_element_tag(module_id) : nil
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
            custom_element_descriptor = nil

            if result.metadata[:javascript_custom_element]
              tag = result.metadata.fetch(:javascript_custom_element_tag)
              code = register_custom_element(module_id, code, tag)
              custom_element_descriptor = custom_element_descriptor(tag, nil)
            end

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
              code: module_source(output_path, custom_element_descriptor: custom_element_descriptor&.merge(asset_path: output_path)),
              assets: [asset, source_map_asset].compact,
              metadata: result.metadata.merge(
                javascript_asset_path: output_path,
                javascript_custom_element_descriptor: custom_element_descriptor&.merge(asset_path: output_path)
              )
            )
          end

          def import_value(_resolved_dependency, record, context)
            return nil unless EXTENSIONS.include?(record.id.extname)

            context.mods.fetch(record.id).const_get(:Exports)::Default
          end

          def runtime_import_value(_resolved_dependency, record, _context)
            return nil unless EXTENSIONS.include?(record.id.extname)

            return record.metadata.fetch(:javascript_custom_element_descriptor) if record.metadata[:javascript_custom_element]

            record.metadata.fetch(:javascript_asset_path)
          end

          private

          def custom_element_module?(module_id)
            CUSTOM_ELEMENT_EXTENSIONS.include?(module_id.extname)
          end

          def jsx_module_source(code)
            %(import { h, Fragment } from "#{JSX_RUNTIME_SPECIFIER}";\n#{code})
          end

          def build_dependencies(module_id, imports)
            imports.filter_map.with_index do |import, index|
              next if external_specifier?(import.specifier)
              raise DynamicImportError, unsupported_specifier_message(import) unless local_specifier?(import.specifier) || import.specifier == JSX_RUNTIME_SPECIFIER

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

          def register_custom_element(module_id, code, tag)
            constructor = custom_element_constructor(module_id, code)
            "#{code.chomp}\ncustomElements.define(#{tag.inspect}, #{constructor});\n"
          end

          def custom_element_constructor(module_id, code)
            if (match = code.match(DEFAULT_EXPORT_CLASS_PATTERN))
              return match[1]
            end

            if (match = code.match(DEFAULT_EXPORT_IDENTIFIER_PATTERN))
              return match[1]
            end

            raise Error, "\"custom element\" modules must default-export a named class or identifier: #{module_id}"
          end

          def custom_element_descriptor(tag, asset_path)
            {
              __klenod_custom_element: true,
              tag: tag,
              asset_path: asset_path
            }
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
            case dependency.importer_id&.extname
            when ".tsx"
              [".tsx", ".ts", ".jsx", ".js"]
            when ".ts"
              [".ts", ".js"]
            when ".jsx"
              [".jsx", ".js"]
            else
              [".js"]
            end
          end

          def source_kind(module_id)
            case module_id.extname
            when ".ts"
              :typescript
            when ".jsx"
              :javascript_jsx
            when ".tsx"
              :typescript_jsx
            else
              :javascript
            end
          end

          def jsx_runtime_source
            <<~JS
              export function h(type, attrs, ...children) {
                if (typeof type === "function") return type(attrs, ...children);

                const el = document.createElement(type);

                for (const [key, value] of Object.entries(attrs || {})) {
                  if (value) {
                    if (value === true) {
                      el.setAttribute(key, key);
                    } else {
                      el.setAttribute(key, value);
                    }
                  }
                }

                appendChildren(el, children);
                return el;
              }

              export function Fragment(_attrs, ...children) {
                const fragment = document.createDocumentFragment();
                appendChildren(fragment, children);
                return fragment;
              }

              function appendChildren(parent, children) {
                children.flat().forEach((child) => {
                  if (child instanceof Node) {
                    parent.appendChild(child);
                  } else if (child) {
                    parent.appendChild(document.createTextNode(String(child)));
                  }
                });
              }
            JS
          end

          def module_source(output_path, custom_element_descriptor: nil)
            default = custom_element_descriptor || output_path

            <<~RUBY
              Default = #{default.inspect}
            RUBY
          end

          def asset_name(module_id)
            module_id.path.gsub(/[^A-Za-z0-9]+/, "_").sub(/\A_+/, "").sub(/_+\z/, "")
          end

          def custom_element_tag(module_id)
            name = asset_name(module_id).downcase.gsub(/_+/, "-")
            hash = Hashing.short(module_id.to_s, length: 8)
            "klenod-#{name}-#{hash}"
          end
        end
      end
    end
  end
end
