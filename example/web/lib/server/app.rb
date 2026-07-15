# frozen_string_literal: true

require "async"
require "async/http"
require "cgi"
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
        watcher = Klenod::Build::Watcher.new(source_dir: source_dir, context: context)
        install_update_handler
        watcher
      end
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
      protocol_response(*error_response_for(request, e, formatted))
    end

    def protocol_response(status, headers, body)
      Protocol::HTTP::Response[status, headers, body]
    end

    def error_response_for(request, error, formatted)
      return plain_error_response(formatted) unless accepts_html?(request)

      [
        500,
        {"content-type" => "text/html; charset=utf-8"},
        [error_page_html(request, error, formatted)]
      ]
    end

    def plain_error_response(formatted)
      [500, {"content-type" => "text/plain; charset=utf-8"}, [ServerFormatting.strip_ansi(formatted), "\n"]]
    end

    def error_page_html(request, error, formatted)
      values = error_template_values(request, error, formatted)
      error_template.gsub(/\{\{([A-Z_]+)\}\}/) { values.fetch(Regexp.last_match(1), "") }
    end

    def error_template
      @error_template ||= File.read(File.join(__dir__, "error_template.html"))
    end

    def error_template_values(request, error, formatted)
      if error.is_a?(Klenod::Build::Plugins::HamlPlugin::ParseError)
        parse_error_template_values(request, error)
      else
        generic_error_template_values(request, error, formatted)
      end
    end

    def parse_error_template_values(request, error)
      cause = error.cause
      title, details = parse_error_details(cause.message)
      location = parse_error_location(error)
      label = location ? "#{location}: Haml parse error" : "Haml parse error"

      {
        "ERROR_LABEL" => escape_html(label),
        "ERROR_TITLE" => escape_html(title),
        "ERROR_CLASS" => escape_html(error.class.name),
        "REQUEST_PATH" => escape_html(request_path(request)),
        "ERROR_LIST" => error_list_html(details),
        "SOURCE_SECTION" => source_section_html(error.source, error.line),
        "BACKTRACE_SECTION" => ""
      }
    end

    def generic_error_template_values(request, error, formatted)
      {
        "ERROR_LABEL" => escape_html(error.class.name),
        "ERROR_TITLE" => escape_html(error.message),
        "ERROR_CLASS" => escape_html(error.class.name),
        "REQUEST_PATH" => escape_html(request_path(request)),
        "ERROR_LIST" => "",
        "SOURCE_SECTION" => "",
        "BACKTRACE_SECTION" => pre_section_html("Backtrace", ServerFormatting.strip_ansi(formatted))
      }
    end

    def parse_error_details(message)
      sections = message.split(/\n\n+/)
      title = sections.shift.to_s
      details =
        sections.flat_map do |section|
          _heading, *lines = section.lines.map(&:chomp)
          lines.map(&:strip).reject(&:empty?)
        end

      [title, details]
    end

    def parse_error_location(error)
      return nil unless error.module_id && error.line

      "#{display_path_for_module(error.module_id)}:#{error.line}"
    end

    def display_path_for_module(module_id)
      source_path = context.graph.absolute_path(module_id)
      Pathname(source_path).relative_path_from(Pathname(config.base_dir)).to_s
    rescue ArgumentError
      module_id.to_s
    end

    def error_list_html(items)
      return "" if items.empty?

      list_items = items.map { |item| "<li>#{escape_html(item)}</li>" }.join
      "<ul class=\"error-list\">#{list_items}</ul>"
    end

    def source_section_html(source, line)
      return "" unless source && line

      pre_section_html("Source", source_excerpt(source, line))
    end

    def source_excerpt(source, line)
      lines = source.lines
      index = line - 1
      first = [index - 2, 0].max
      last = [index + 2, lines.length - 1].min
      width = (last + 1).to_s.length

      (first..last).map do |line_index|
        marker = (line_index == index) ? ">" : " "
        number = (line_index + 1).to_s.rjust(width)
        "#{marker} #{number} | #{lines.fetch(line_index).chomp}"
      end.join("\n")
    end

    def pre_section_html(title, content)
      <<~HTML
        <section class="panel">
          <h2>#{escape_html(title)}</h2>
          <pre><code>#{escape_html(content)}</code></pre>
        </section>
      HTML
    end

    def accepts_html?(request)
      accept = request_headers(request).fetch("accept", "").to_s
      return true if accept.empty?

      ["text/html", "*/*"].include?(preferred_accept_type(accept))
    end

    def request_headers(request)
      headers = request&.headers
      return {} unless headers

      index = {}
      headers.each { |name, value| index[name.to_s.downcase] = value }
      index
    end

    def preferred_accept_type(accept)
      accept
        .split(",")
        .map
        .with_index { |entry, index| accept_entry(entry, index) }
        .compact
        .max_by { |entry| [entry.fetch(:quality), -entry.fetch(:index)] }
        &.fetch(:type, nil)
    end

    def accept_entry(entry, index)
      type, *params = entry.strip.split(";").map(&:strip)
      return nil if type.empty?

      quality =
        params
          .find { |param| param.start_with?("q=") }
          &.delete_prefix("q=")
          &.to_f || 1.0
      {type:, quality:, index:}
    end

    def request_path(request)
      path = request&.path.to_s
      path.empty? ? "/" : path
    end

    def escape_html(value)
      CGI.escapeHTML(value.to_s)
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
