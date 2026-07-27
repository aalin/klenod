# frozen_string_literal: true

require "brotli"
require "fileutils"

module Klenod
  module Build
    module AssetCompression
      TEXT_CONTENT_TYPES = [
        "application/javascript",
        "application/json",
        "application/manifest+json",
        "application/rss+xml",
        "application/xml",
        "image/svg+xml"
      ].freeze

      def self.compressible?(asset)
        content_type = asset.content_type.to_s.split(";", 2).first
        content_type.start_with?("text/") || TEXT_CONTENT_TYPES.include?(content_type)
      end

      def self.sidecar_path(path)
        "#{path}.br"
      end

      def self.write_sidecar(asset, path)
        return nil unless compressible?(asset)

        brotli_path = sidecar_path(path)
        return :skipped if File.file?(brotli_path)

        bytes = asset.bytes
        compressed = Brotli.deflate(bytes, quality: 11, mode: :text)
        return nil unless compressed.bytesize < bytes.bytesize

        write_atomic(brotli_path, compressed)
        :written
      end

      def self.remove_sidecar(path)
        brotli_path = sidecar_path(path)
        FileUtils.rm_f(brotli_path)
        brotli_path
      end

      def self.write_atomic(path, bytes)
        temp_path = "#{path}.tmp.#{$$}.#{object_id}"
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(temp_path, bytes)
        File.rename(temp_path, path)
      rescue
        FileUtils.rm_f(temp_path) if temp_path
        raise
      end
    end
  end
end
