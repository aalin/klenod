# frozen_string_literal: true

require "async"
require "async/http"
require "protocol/http/response"

require_relative "../../../../lib/klenod"
require_relative "../dev/update_logger"
require_relative "errors"
require_relative "formatting"

module Example
  class DevServer
    ERROR_LOG_REPEAT_INTERVAL = 2.0

    def initialize(config_path:, port: Integer(ENV.fetch("PORT", "9292")), assets_dir: ENV["ASSETS_DIR"])
      @config = Klenod::Build::ConfigLoader.load(config_path)
      @port = port
      @assets_dir = assets_dir && File.expand_path(assets_dir)
    end

    def run
      ServerFormatting.suppress_io_buffer_experimental_warning
      entry
      asset_app
      ServerFormatting.log_startup(port:, source_dir:, assets_dir:)

      begin
        watcher.start

        Async do
          server = Async::HTTP::Server.for(endpoint) { |request| response_for(request) }
          server.run.wait
        end
      ensure
        watcher&.stop
      end
    end

    private

    attr_reader :config, :port, :assets_dir

    def source_dir
      @source_dir ||= config.source_path
    end

    def entrypoint
      @entrypoint ||= config.entrypoints.fetch(0)
    end

    def endpoint
      @endpoint ||= Async::HTTP::Endpoint.parse("http://localhost:#{port}")
    end

    def context
      @context ||= config.context
    end

    def entry
      @entry ||= context.entry(entrypoint)
    end

    def watcher
      @watcher ||= begin
        watcher = Klenod::Dev::Watcher.new(source_dir: source_dir, context: context)
        install_update_handler
        watcher
      end
    end

    def asset_app
      @asset_app ||= begin
        context.write_assets(assets_dir) if assets_dir
        Klenod::HTTP::AssetApp.new(context, assets_dir: assets_dir)
      end
    end

    def update_logger
      @update_logger ||= UpdateLogger.new(source_dir: source_dir)
    end

    def install_update_handler
      context.on_update do |event|
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        update = context.apply_update(event, entry: entry, assets_dir: assets_dir)

        update_logger.log(event: event, update: update, duration: ServerFormatting.duration_ms(start_time)) do |module_id, error|
          ServerErrors.format_update_error(module_id, error, context)
        end

        if update.failed?
          update.each_error { |_module_id, error| remember_logged_error(error) }
        else
          clear_logged_errors
        end
      end
    end

    def response_for(request)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      if (asset_response = asset_app.response_for(request.path))
        status, headers, body = asset_response.status, asset_response.headers, [asset_response.body]
      else
        status, headers, body = entry.call(request, context)
      end
      ServerFormatting.log_request(request, status, start_time)
      protocol_response(status, headers, body)
    rescue => e
      formatted = ServerErrors.format_exception(e, context)
      log_error_unless_recent(e, formatted)
      ServerFormatting.log_request(request, 500, start_time) if start_time
      protocol_response(500, {"content-type" => "text/plain"}, [ServerFormatting.strip_ansi(formatted), "\n"])
    end

    def protocol_response(status, headers, body)
      Protocol::HTTP::Response[status, headers, body]
    end

    def remember_logged_error(error, logged_at: current_time)
      logged_errors[error_log_key(error)] = logged_at
    end

    def logged_error?(error)
      logged_errors.key?(error_log_key(error))
    end

    def recently_logged_error?(error, now: current_time)
      logged_at = logged_errors[error_log_key(error)]
      logged_at && (now - logged_at) < ERROR_LOG_REPEAT_INTERVAL
    end

    def clear_logged_errors
      logged_errors.clear
    end

    def logged_errors
      @logged_errors ||= {}
    end

    def error_log_key(error)
      [error.class.name, ServerFormatting.strip_ansi(error.message)]
    end

    def log_error_unless_recent(error, formatted)
      return if recently_logged_error?(error)

      warn formatted
      remember_logged_error(error)
    end

    def current_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
