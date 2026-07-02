# frozen_string_literal: true

require "digest"

require_relative "../asset"
require_relative "../plugin"
require_relative "../transform_result"

module Klenod
  module Build
    module Plugins
      class ImagePlugin < Plugin
        EXTENSIONS = [".avif", ".gif", ".jpeg", ".jpg", ".png", ".webp"].freeze

        Image = Data.define(:src, :width, :height, :variants)

        def transform(module_id, code, _context)
          return super unless EXTENSIONS.include?(module_id.extname)

          hash = Digest::SHA256.hexdigest(code)[0, 16]
          output_path = "/assets/#{asset_name(module_id)}.#{hash}#{module_id.extname}"
          asset =
            Asset.new(
              module_id.to_s,
              hash,
              output_path,
              nil,
              code,
              content_type(module_id.extname),
              {type: :image}
            )

          TransformResult.new("", [], nil, [asset], {asset_bytes: code})
        end

        def import_value(_resolved_dependency, record, _context)
          return nil unless EXTENSIONS.include?(record.id.extname)

          Image.new(record.assets.first.output_path, nil, nil, {})
        end

        private

        def asset_name(module_id)
          File.basename(module_id.path, module_id.extname).gsub(/[^A-Za-z0-9]+/, "_")
        end

        def content_type(extname)
          case extname
          when ".avif" then "image/avif"
          when ".gif" then "image/gif"
          when ".jpeg", ".jpg" then "image/jpeg"
          when ".png" then "image/png"
          when ".webp" then "image/webp"
          else "application/octet-stream"
          end
        end
      end
    end
  end
end
