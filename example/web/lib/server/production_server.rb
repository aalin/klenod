# frozen_string_literal: true

require "klenod/rack"
require "klenod/runtime"

require_relative "../framework"
require_relative "formatting"
require_relative "runner"

module Example
  class ProductionServer
    APP_ROOT = File.expand_path("../..", __dir__)
    DEFAULT_BUNDLE_PATH = File.join(APP_ROOT, "dist/klenod.bundle")
    DEFAULT_ASSETS_DIR = File.join(APP_ROOT, "dist/public")
    DEFAULT_SOURCE_ROOT = File.join(APP_ROOT, "src")
    DEFAULT_ENTRYPOINT = "/entrypoint.rb"

    def initialize(
      bundle_path: ENV.fetch("BUNDLE_PATH", DEFAULT_BUNDLE_PATH),
      assets_dir: ENV.fetch("ASSETS_DIR", DEFAULT_ASSETS_DIR),
      source_root: ENV.fetch("SOURCE_ROOT", DEFAULT_SOURCE_ROOT),
      entrypoint: ENV.fetch("ENTRYPOINT", DEFAULT_ENTRYPOINT),
      host: ENV.fetch("HOST", "localhost"),
      port: Integer(ENV.fetch("PORT", "9292"))
    )
      @bundle_path = File.expand_path(bundle_path)
      @assets_dir = File.expand_path(assets_dir)
      @source_root = File.expand_path(source_root)
      @entrypoint = entrypoint
      @host = host
      @port = port
    end

    def run
      ServerFormatting.suppress_io_buffer_experimental_warning
      bundle.preload_entrypoints
      asset_app
      ServerFormatting.log_startup(host:, port:, source_dir: source_root, assets_dir: assets_dir, source_label: "source")
      server_runner.run
    end

    private

    attr_reader :bundle_path, :assets_dir, :source_root, :entrypoint, :host, :port

    def bundle
      @bundle ||= Klenod::Runtime.load_bundle(bundle_path, source_root: source_root)
    end

    def entry
      @entry ||= bundle.exports(entrypoint)
    end

    def asset_app
      @asset_app ||= Klenod::Rack::AssetApp.new(bundle, assets_dir: assets_dir)
    end

    def server_runner
      @server_runner ||=
        ServerRunner.new(
          port: port,
          host: host,
          asset_app: asset_app,
          app: ->(request) { entry.call(request, bundle) },
          error_handler: ->(_request, error) { error_response_for(error) }
        )
    end

    def error_response_for(error)
      warn error.full_message
      [
        500,
        {"content-type" => "text/plain; charset=utf-8"},
        ["Internal server error\n"]
      ]
    end
  end
end
