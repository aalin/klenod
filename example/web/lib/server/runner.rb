# frozen_string_literal: true

require "async"
require "async/http"
require "async/http/protocol/https"
require "localhost"
require "protocol/http/response"

require_relative "formatting"

module Example
  class ServerRunner
    def initialize(port:, asset_app:, app:, error_handler:, host: "localhost")
      @host = host
      @port = port
      @asset_app = asset_app
      @app = app
      @error_handler = error_handler
    end

    attr_reader :host, :port

    def scheme
      "https"
    end

    def protocol_name
      "HTTPS + HTTP/2 + HTTP/1.x"
    end

    def run
      Async do
        server = Async::HTTP::Server.for(endpoint) { |request| response_for(request) }
        server.run.wait
      end
    rescue Interrupt
      puts
      ServerFormatting.log_shutdown
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

    def endpoint
      @endpoint ||= Async::HTTP::Endpoint.parse("#{scheme}://#{host}:#{port}", protocol: protocol, ssl_context: ssl_context)
    end

    def protocol
      Async::HTTP::Protocol::HTTPS
    end

    def ssl_context
      @ssl_context ||= Localhost::Authority.fetch(host).server_context.tap do |context|
        protocols = Async::HTTP::Protocol::HTTPS.names
        context.alpn_protocols = protocols

        context.alpn_select_cb = lambda do |offered_protocols|
          protocols.find { |protocol| offered_protocols.include?(protocol) }
        end
      end
    end

    def response_tuple_for(request)
      if (asset_response = @asset_app.response_for(request.path, rack_env_for(request)))
        [asset_response.status, asset_response.headers, [asset_response.body]]
      else
        @app.call(request)
      end
    end

    def protocol_response(status, headers, body)
      headers = headers.reject { |name, _value| name.to_s.downcase == "content-length" }
      Protocol::HTTP::Response[status, headers, body]
    end

    def rack_env_for(request)
      {
        "HTTP_ACCEPT_ENCODING" => header_value(request, "accept-encoding")
      }
    end

    def header_value(request, name)
      headers = request.headers if request.respond_to?(:headers)
      return "" unless headers&.respond_to?(:each)

      values = []
      headers.each do |header|
        header_name, value = header
        values << value.to_s if header_name.to_s.downcase == name
      end
      values.join(", ")
    end
  end
end
