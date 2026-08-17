# frozen_string_literal: true

require "http/accept"

module Klenod
  module Rack
    Response = Data.define(:status, :headers, :body) do
      def rack_response
        [status, headers, [body]]
      end

      def protocol_response
        require "protocol/http/response"

        Protocol::HTTP::Response[status, headers, [body]]
      end
    end

    class AssetApp
      CACHE_CONTROL = "public, max-age=31536000, immutable"

      def initialize(source, app: nil, assets_dir: nil, path_prefix: "/assets/")
        @source = source
        @app = app
        @assets_dir = assets_dir
        @path_prefix = path_prefix
      end

      attr_reader :source, :app, :assets_dir, :path_prefix

      def call(env)
        response = response_for(env.fetch("PATH_INFO", ""), env)
        return response.rack_response if response
        return app.call(env) if app

        not_found.rack_response
      end

      def response_for(path, env = {})
        return nil unless asset_path?(path)

        asset = source.asset(path)
        brotli_available = brotli_asset_available?(asset)
        compressed = brotli_available && accepts_brotli?(env.fetch("HTTP_ACCEPT_ENCODING", ""))
        body = compressed ? brotli_asset_bytes(asset) : asset_bytes(asset)
        headers = {
          "content-type" => asset.content_type,
          "content-length" => body.bytesize.to_s,
          "cache-control" => CACHE_CONTROL
        }
        link = preload_link_header(asset)
        headers["link"] = link if link
        headers["vary"] = "Accept-Encoding" if brotli_available
        if compressed
          headers["content-encoding"] = "br"
        end

        Response.new(
          200,
          headers,
          body
        )
      rescue KeyError, Errno::ENOENT
        not_found
      end

      private

      def asset_path?(path)
        path.start_with?(path_prefix)
      end

      def asset_bytes(asset)
        if source.respond_to?(:asset_bytes)
          source.asset_bytes(asset.output_path, assets_dir: assets_dir)
        else
          File.binread(asset_disk_path(asset.output_path))
        end
      end

      def brotli_asset_available?(asset)
        return false unless assets_dir

        File.file?(brotli_asset_disk_path(asset.output_path))
      end

      def accepts_brotli?(header)
        return false if header.to_s.strip.empty?

        HTTP::Accept::Encodings.parse(header.to_s).any? do |encoding|
          %w[br *].include?(encoding.encoding) && encoding.quality_factor.positive?
        end
      rescue HTTP::Accept::ParseError
        false
      end

      def preload_link_header(asset)
        links =
          Array(asset.metadata[:preload_assets]).map do |preload|
            path = preload.fetch(:path)
            as = preload.fetch(:as)
            %(<#{path}>; rel=preload; as=#{as})
          end

        links.empty? ? nil : links.join(", ")
      end

      def brotli_asset_bytes(asset)
        File.binread(brotli_asset_disk_path(asset.output_path))
      end

      def brotli_asset_disk_path(output_path)
        "#{asset_disk_path(output_path)}.br"
      end

      def asset_disk_path(output_path)
        raise ArgumentError, "assets_dir is required to serve runtime bundle assets" unless assets_dir

        File.join(assets_dir, output_path.delete_prefix("/"))
      end

      def not_found
        Response.new(
          404,
          {
            "content-type" => "text/plain",
            "content-length" => "16"
          },
          "Asset not found\n"
        )
      end
    end
  end
end
