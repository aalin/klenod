# frozen_string_literal: true

require "async"
require "async/http"
require "protocol/http/response"

require_relative "formatting"

module Example
  class ServerRunner
    def initialize(port:, asset_app:, app:, error_handler:)
      @port = port
      @asset_app = asset_app
      @app = app
      @error_handler = error_handler
    end

    def run
      Async do
        server = Async::HTTP::Server.for(endpoint) { |request| response_for(request) }
        server.run.wait
      end
    end

    def response_for(request)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status, headers, body = response_tuple_for(request)
      ServerFormatting.log_request(request, status, start_time)
      protocol_response(status, headers, body)
    rescue => error
      status, headers, body = @error_handler.call(request, error)
      ServerFormatting.log_request(request, status, start_time) if start_time
      protocol_response(status, headers, body)
    end

    private

    attr_reader :port

    def endpoint
      @endpoint ||= Async::HTTP::Endpoint.parse("http://localhost:#{port}")
    end

    def response_tuple_for(request)
      if (asset_response = @asset_app.response_for(request.path))
        [asset_response.status, asset_response.headers, [asset_response.body]]
      else
        @app.call(request)
      end
    end

    def protocol_response(status, headers, body)
      Protocol::HTTP::Response[status, headers, body]
    end
  end
end
