# frozen_string_literal: true

require "klenod/build/resolution_error_formatter"

module Example
  module ServerErrors
    module_function

    def format_exception(error, context)
      return format_parse_update_error(error) if error.is_a?(Klenod::Build::Plugins::HamlPlugin::ParseError)

      mods =
        context.graph.mods.each_with_object({}) do |(module_id, mod), index|
          index[module_id.to_s] = mod
          index[module_id.path] = mod
        end

      rewriter = Klenod::Runtime::BacktraceRewriter.new(mods)
      return rewriter.format_exception(error) unless resolution_error?(error)

      formatted = Klenod::Build::ResolutionErrorFormatter.format(error)
      title, details = formatted.split("\n", 2)
      rewriter.format_exception(error, title: title, details: details&.sub(/\A\n/, ""))
    end

    def format_update_error(module_id, error, context)
      return format_parse_update_error(error) if error.is_a?(Klenod::Build::Plugins::HamlPlugin::ParseError)

      if resolution_error?(error)
        return [
          Klenod::Build::ResolutionErrorFormatter.format(error),
          source_context_for_resolution_error(error, context)
        ].compact.join("\n\n")
      end

      [
        "#{module_id}: #{error.class}",
        error.message,
        source_context_for_update_error(module_id, error, context)
      ].compact.join("\n\n")
    end

    def format_parse_update_error(error)
      reset = "\e[0;48;5;52m"
      lines = error.message.lines
      title = lines.shift&.chomp || "#{error.class}: #{error.message}"
      body = strip_ansi(lines.join)

      [
        "\e[1;31;47m ERROR \e[3;31;47m #{title} #{reset}",
        body.empty? ? nil : color_parse_error_body(body),
        "\e[0m"
      ].compact.join("\n")
    end

    def color_parse_error_body(body)
      body
        .sub(/\A\n+/, "")
        .sub(/\A(.+?)(\n\n|\z)/m) { "\e[1;31m#{$1}\e[0;48;5;52m#{$2}" }
        .sub(/^Source:/, "\e[1;34mSource:\e[0;48;5;52m")
    end

    def strip_ansi(value)
      value.gsub(/\e\[[0-9;]*m/, "")
    end

    def resolution_error?(error)
      error.is_a?(Klenod::Build::ResolveError) && error.resolution_failure?
    end

    def source_context_for_resolution_error(error, context)
      location = error.source_location
      return nil unless location&.line

      module_id = Klenod::Build::ModuleId.parse(location.path)
      source_path = context.graph.absolute_path(module_id)
      return nil unless source_path.file?

      source_excerpt(source_path.read, location.line)
    rescue Klenod::Build::ResolveError, ArgumentError
      nil
    end

    def source_context_for_update_error(module_id, error, context)
      return nil if error.is_a?(Klenod::Build::Plugins::HamlPlugin::ParseError)
      return nil unless error.respond_to?(:line)

      source_path = context.graph.absolute_path(module_id)
      return nil unless source_path.file?

      line = error.line
      return nil unless line.is_a?(Integer)

      # Haml reports zero-based line indexes.
      line += 1
      source_excerpt(File.read(source_path), line)
    end

    def source_excerpt(source, line)
      lines = source.lines
      return nil if lines.empty?

      index = line - 1
      first = [index - 2, 0].max
      last = [index + 2, lines.length - 1].min
      width = (last + 1).to_s.length
      excerpt =
        (first..last).map do |line_index|
          marker = (line_index == index) ? ">" : " "
          number = (line_index + 1).to_s.rjust(width)
          formatted = "#{marker} #{number} | #{lines.fetch(line_index).chomp}"
          if marker == ">"
            "\e[1;31m#{formatted}\e[0m"
          else
            formatted
          end
        end

      "Source:\n#{excerpt.join("\n")}"
    end
  end
end
