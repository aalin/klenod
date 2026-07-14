# frozen_string_literal: true

module Klenod
  module HTTP
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
        response = response_for(env.fetch("PATH_INFO", ""))
        return response.rack_response if response
        return app.call(env) if app

        not_found.rack_response
      end

      def response_for(path)
        return nil unless asset_path?(path)

        asset = source.asset(path)
        body = asset_bytes(asset)

        Response.new(
          200,
          {
            "content-type" => asset.content_type,
            "content-length" => body.bytesize.to_s,
            "cache-control" => CACHE_CONTROL
          },
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
