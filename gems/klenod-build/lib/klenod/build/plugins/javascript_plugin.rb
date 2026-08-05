# frozen_string_literal: true

require_relative "../asset"
require_relative "../hashing"
require_relative "../plugin"
require_relative "../transform_result"

module Klenod
  module Build
    module Plugins
      module JavaScriptPlugin
        class Plugin < Klenod::Build::Plugin
          CONTENT_TYPE = "application/javascript"
          EXTENSIONS = [".js"].freeze

          def transform(module_id, code, _context)
            return super unless EXTENSIONS.include?(module_id.extname)

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

            TransformResult.new(
              module_source(output_path),
              [],
              nil,
              [asset],
              [],
              {javascript_asset_path: output_path}
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
