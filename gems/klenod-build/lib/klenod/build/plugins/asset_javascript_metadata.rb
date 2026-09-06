# frozen_string_literal: true

require "json"

require_relative "../asset"
require_relative "../hashing"

module Klenod
  module Build
    module Plugins
      module AssetJavaScriptMetadata
        IDENTIFIER_PATTERN = /\A[$A-Z_a-z][$0-9A-Z_a-z]*\z/
        LOGICAL_NAME = "virtual:klenod/asset-metadata.js"
        SOURCE = <<~JAVASCRIPT
          export class ImageBase {
            constructor({ src, width, height, contentType, aspectRatio }) {
              this.src = src;
              this.width = width;
              this.height = height;
              this.contentType = contentType;
              this.aspectRatio = aspectRatio;
            }
          }

          export class ImageVariant extends ImageBase {
            constructor({ src, width, height, contentType, aspectRatio, format, descriptor, quality }) {
              super({ src, width, height, contentType, aspectRatio });
              this.format = format;
              this.descriptor = descriptor;
              this.quality = quality;
              Object.freeze(this);
            }
          }

          export default class ImageMetadata extends ImageBase {
            constructor({ src, width, height, contentType, aspectRatio, variants = [], placeholder = null }) {
              super({ src, width, height, contentType, aspectRatio });
              this.variants = Object.freeze([...variants]);
              this.placeholder = placeholder;
              Object.freeze(this);
            }

            get srcset() {
              if (this.variants.length === 0) return null;
              return this.variants.map((variant) => `${variant.src} ${variant.descriptor}`).join(", ");
            }

            get sizes() {
              const variantWidths = this.variants.map((variant) => variant.width).filter(Boolean);
              const displayWidth = variantWidths.length > 0 ? Math.max(...variantWidths) : this.width;
              return displayWidth ? `(max-width: ${displayWidth}px) 100vw, ${displayWidth}px` : null;
            }
          }

          export class SvgMetadata extends ImageBase {
            constructor({ src, width, height, contentType, aspectRatio }) {
              super({ src, width, height, contentType, aspectRatio });
              Object.freeze(this);
            }
          }
        JAVASCRIPT
        CONTENT_HASH = Hashing.short(SOURCE)
        OUTPUT_PATH = "/klenod_asset_metadata.#{CONTENT_HASH}.js"

        module_function

        def object_literal(properties)
          "{#{properties.map { |key, value| property(key, value) }.join(",")}}"
        end

        def aspect_ratio(width, height)
          return nil unless width && height && !height.zero?

          width.to_f / height
        end

        def property(key, value)
          name = key.to_s
          name = JSON.generate(name) unless name.match?(IDENTIFIER_PATTERN)
          "#{name}:#{JSON.generate(value)}"
        end

        def asset
          Asset.new(
            LOGICAL_NAME,
            CONTENT_HASH,
            OUTPUT_PATH,
            nil,
            SOURCE,
            "application/javascript",
            {type: :javascript, javascript_runtime: :asset_metadata}
          )
        end
      end
    end
  end
end
