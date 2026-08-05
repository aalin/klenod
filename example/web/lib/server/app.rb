# frozen_string_literal: true

require "klenod"
require_relative "../framework"
require_relative "../web_config"
require_relative "../dev/update_logger"
require_relative "chrome_devtools_probe"
require_relative "development_error_page"
require_relative "errors"
require_relative "formatting"
require_relative "production_server"
require_relative "recent_error_log"
require_relative "runner"

module Example
  class DevServer
    ERROR_LOG_REPEAT_INTERVAL = RecentErrorLog::DEFAULT_REPEAT_INTERVAL

    def initialize(config: WebConfig.build_config, host: ENV.fetch("HOST", "localhost"), port: Integer(ENV.fetch("PORT", "9292")), assets_dir: ENV["ASSETS_DIR"])
      @config = config
      @host = host
      @port = port
      @assets_dir = assets_dir && File.expand_path(assets_dir)
    end

    def run
      ServerFormatting.suppress_io_buffer_experimental_warning
      entry
      asset_app
      runner = server_runner
      ServerFormatting.log_startup(host:, port:, source_dir:, assets_dir:, scheme: runner.scheme, protocol: runner.protocol_name)

      begin
        watcher.start

        runner.run
      ensure
        watcher&.stop
      end
    end

    private

    attr_reader :config, :host, :port, :assets_dir

    def source_dir
      @source_dir ||= config.source_path
    end

    def entrypoint
      @entrypoint ||= config.entrypoints.fetch(0)
    end

    def context
      @context ||= config.context
    end

    def entry
      @entry ||= context.entry(entrypoint)
    end

    def watcher
      @watcher ||= begin
        watcher = Klenod::Build::Watcher.new(source_dir: source_dir, context: context)
        install_update_handler
        watcher
      end
    end

    def server_runner
      @server_runner ||=
        ServerRunner.new(
          port: port,
          host: host,
          asset_app: asset_app,
          app: ->(request) { dev_response_for(request) || entry.call(request, context) },
          error_handler: ->(request, error) { handle_request_error(request, error) }
        )
    end

    def dev_response_for(request)
      chrome_devtools_probe.response_for(request)
    end

    def asset_app
      @asset_app ||= begin
        context.write_assets(assets_dir) if assets_dir
        Klenod::Rack::AssetApp.new(context, assets_dir: assets_dir)
      end
    end

    def update_logger
      @update_logger ||= UpdateLogger.new(source_dir: source_dir)
    end

    def chrome_devtools_probe
      @chrome_devtools_probe ||= ChromeDevtoolsProbe.new(source_dir: source_dir)
    end

    def error_page
      @error_page ||= DevelopmentErrorPage.new(config: config, context: context)
    end

    def recent_error_log
      @recent_error_log ||= RecentErrorLog.new
    end

    def install_update_handler
      context.on_update do |event|
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        update = context.apply_update(event, entry: entry, assets_dir: assets_dir)

        update_logger.log(event: event, update: update, duration: ServerFormatting.duration_ms(start_time)) do |module_id, error|
          ServerErrors.format_update_error(module_id, error, context)
        end

        if update.failed?
          update.each_error { |_module_id, error| recent_error_log.remember(error) }
        else
          recent_error_log.clear
        end
      end
    end

    def handle_request_error(request, error)
      formatted = ServerErrors.format_exception(error, context)
      recent_error_log.warn_unless_recent(error, formatted)
      error_page.response_for(request, error, formatted)
    end
  end
end
