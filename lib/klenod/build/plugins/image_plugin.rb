# frozen_string_literal: true

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

          TransformResult.new("", [], nil, [], {asset_bytes: code})
        end

        def import_value(_resolved_dependency, record, _context)
          return nil unless EXTENSIONS.include?(record.id.extname)

          Image.new(record.id.to_s, nil, nil, {})
        end
      end
    end
  end
end
