# frozen_string_literal: true

require_relative "formatting"

module Example
  class DevelopmentErrorPage
    def initialize(config:, context:)
      @config = config
      @context = context
    end

    def response_for(request, error, formatted)
      return plain_response(formatted) unless accepts_html?(request)

      [
        500,
        {"content-type" => "text/html; charset=utf-8"},
        [html(request, error, formatted)]
      ]
    end

    private

    attr_reader :config, :context

    def plain_response(formatted)
      [500, {"content-type" => "text/plain; charset=utf-8"}, [ServerFormatting.strip_ansi(formatted), "\n"]]
    end

    def html(request, error, formatted)
      values = template_values(request, error, formatted)
      template.gsub(/\{\{([A-Z_]+)\}\}/) { values.fetch(Regexp.last_match(1), "") }
    end

    def template
      @template ||= File.read(File.join(__dir__, "error_template.html"))
    end

    def template_values(request, error, formatted)
      if error.is_a?(Klenod::Build::Plugins::HamlPlugin::ParseError)
        parse_error_values(request, error)
      elsif resolution_error?(error)
        resolution_error_values(request, error, formatted)
      else
        generic_error_values(request, error, formatted)
      end
    end

    def resolution_error_values(request, error, formatted)
      {
        "ERROR_LABEL" => "Module resolution error",
        "ERROR_TITLE" => escape_html(error.title),
        "ERROR_CLASS" => escape_html(error.class.name),
        "REQUEST_PATH" => escape_html(request_path(request)),
        "ERROR_LIST" => resolution_details_html(error),
        "SOURCE_SECTION" => resolution_source_section_html(error),
        "BACKTRACE_SECTION" => resolution_backtrace_section_html(formatted)
      }
    end

    def parse_error_values(request, error)
      title, details = parse_error_details(error.cause.message)
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

    def generic_error_values(request, error, formatted)
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

    def resolution_details_html(error)
      rows = [resolution_detail_row("Import", error.requested_specifier)]
      rows << resolution_detail_row("Imported by", error.imported_by) if error.imported_by
      suggestions =
        if error.suggestions.empty?
          ""
        else
          label = (error.reason == :incorrect_case) ? "Use" : "Did you mean?"
          items = error.suggestions.map { |suggestion| "<li><code>#{escape_html(suggestion)}</code></li>" }.join
          "<div class=\"resolution-suggestions\"><strong>#{label}</strong><ul>#{items}</ul></div>"
        end

      "<dl class=\"resolution-details\">#{rows.join}</dl>#{suggestions}"
    end

    def resolution_detail_row(label, value)
      "<div><dt>#{label}</dt><dd><code>#{escape_html(value)}</code></dd></div>"
    end

    def resolution_source_section_html(error)
      location = error.source_location
      return "" unless location&.line && context

      module_id = Klenod::Build::ModuleId.parse(location.path)
      source_path = context.graph.absolute_path(module_id)
      return "" unless source_path.file?

      source_section_html(source_path.read, location.line)
    rescue Klenod::Build::ResolveError, ArgumentError
      ""
    end

    def resolution_backtrace_section_html(formatted)
      plain = ServerFormatting.strip_ansi(formatted)
      _summary, separator, backtrace = plain.partition("Backtrace:\n")
      return "" if separator.empty? || backtrace.strip.empty?

      pre_section_html("Backtrace", backtrace.strip)
    end

    def resolution_error?(error)
      error.is_a?(Klenod::Build::ResolveError) && error.resolution_failure?
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
  end
end
