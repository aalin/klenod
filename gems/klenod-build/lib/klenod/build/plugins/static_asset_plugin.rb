# frozen_string_literal: true

require_relative "../asset"
require_relative "../hashing"
require_relative "../plugin"
require_relative "../transform_result"

module Klenod
  module Build
    module Plugins
      module StaticAssetPlugin
        def self.new(...)
          Plugin.new(...)
        end

        class Plugin < Klenod::Build::Plugin
          CONTENT_TYPES = {
            ".otf" => "font/otf",
            ".ttf" => "font/ttf",
            ".woff" => "font/woff",
            ".woff2" => "font/woff2"
          }.freeze

          def transform(module_id, code, context)
            return super unless CONTENT_TYPES.key?(module_id.extname)

            hash = Hashing.short(code)
            output_path = "/#{asset_name(module_id)}.#{hash}#{module_id.extname}"
            asset = Asset.new(module_id.path, hash, output_path, nil, code, CONTENT_TYPES.fetch(module_id.extname), {type: :static_asset})
            asset.url = context.asset_url(output_path)

            TransformResult.new("Default = #{asset.url.inspect}\n", [], nil, [asset], [], {})
          end

          def import_value(_resolved_dependency, record, context)
            return nil unless CONTENT_TYPES.key?(record.id.extname)

            context.mods.fetch(record.id).const_get(:Exports)::Default
          end

          def runtime_import_value(_resolved_dependency, record, _context)
            return nil unless CONTENT_TYPES.key?(record.id.extname)

            Runtime::DefaultImport.new(:Default)
          end

          private

          def asset_name(module_id)
            File.basename(module_id.path, module_id.extname).gsub(/[^A-Za-z0-9]+/, "_")
          end
        end
      end
    end
  end
end
