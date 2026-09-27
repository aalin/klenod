# frozen_string_literal: true

module Klenod
  module Build
    # Shared formatting for build errors that can point at a line of source.
    #
    # Plugins raise errors carrying the original source and a location, and the
    # resulting message is shown both in the terminal and in the browser error
    # dialog, so it needs to read well as plain text. The browser passes
    # `ansi: false` to get the same layout without escape codes.
    module SourceExcerpt
      MARKED_LINE = "\e[1;31m"
      KIND = "\e[1;31m"
      DETAIL = "\e[31m"
      HINT_LABEL = "\e[1;36m"
      HINT = "\e[36m"
      LOCATION = "\e[34m"
      BOLD = "\e[1m"
      NOT_BOLD = "\e[22m"
      DIM = "\e[2m"
      RESET = "\e[0m"

      module_function

      # "app:/pages/thing.tsx:33:9"
      def location(module_id:, line:, column: nil)
        if module_id && line
          "#{module_id}:#{[line, column].compact.join(":")}"
        elsif module_id
          module_id.to_s
        elsif line
          column ? "line #{line} column #{column}" : "line #{line}"
        end
      end

      # The kind and detail share a header line. The location goes in the
      # excerpt's frame, or on an "at" line when there is no excerpt, and the
      # hints follow:
      #
      #   × Haml parse error: Could not parse Ruby filter
      #
      #       ╭─[app:/pages/page.haml:4]
      #     3 │     @count = 0
      #   > 4 │
      #       ╰────
      #     hint: Unmatched keyword, missing `end' ?
      #
      # With `path`, the file the module was read from, the location links to
      # that file when `links` is on.
      def message(module_id:, line:, kind:, source:, message:, column: nil, hints: [], context: 2, ansi: true, path: nil, links: ansi && hyperlinks?)
        location = styled_location(module_id:, line:, column:, path:, ansi:, links:)
        excerpt = excerpt(source:, line:, column:, context:, ansi:, location:)
        hints = hint_section(hints, ansi:)&.gsub(/^/, "  ")
        header = header(kind, message, ansi:)

        unless excerpt
          header = "#{header}\n  #{dim("at", ansi:)} #{location}" if location
          return [header, hints].compact.join("\n\n")
        end

        [header, [excerpt, hints].compact.join("\n")].join("\n\n")
      end

      # "× JSON parse error: expected object key". Later lines of a multi-line
      # detail are indented under the first.
      def header(kind, message, ansi: true)
        first, *rest = message.to_s.lines(chomp: true)
        label = first ? "× #{kind}:" : "× #{kind}"
        label = "#{KIND}#{label}#{RESET}" if ansi
        return label unless first

        [
          "#{label} #{detail(first, ansi:)}",
          *rest.map { it.empty? ? it : "  #{detail(it, ansi:)}" }
        ].join("\n")
      end

      # The location in blue with the file name in bold, linked to `path` when
      # `links` is on and the file exists.
      def styled_location(module_id:, line: nil, column: nil, path: nil, ansi: true, links: ansi && hyperlinks?)
        location = location(module_id:, line:, column:)
        return location unless ansi && location

        location = bold_file_name(location, module_id) if module_id
        location = file_link(location, path:, line:, column:) if links && path && File.file?(path.to_s)
        "#{LOCATION}#{location}#{RESET}"
      end

      # "app:\e[1m/pages/thing.tsx\e[22m:33:9": the file name stands out from its
      # scheme and position.
      def bold_file_name(location, module_id)
        scheme, name = module_id.to_s.match(/\A([a-z][a-z0-9+.-]*:)?(.*)\z/i).captures
        location.sub(module_id.to_s) { "#{scheme}#{BOLD}#{name}#{NOT_BOLD}" }
      end

      # Whether the terminal turns OSC 8 sequences into clickable links. There
      # is no way to ask, so this recognises the terminals known to do it.
      def hyperlinks?(env = ENV)
        return false if env.key?("NO_COLOR")
        return true if %w[iTerm.app WezTerm vscode ghostty Hyper Tabby rio].include?(env["TERM_PROGRAM"])
        return true if %w[xterm-kitty foot contour].include?(env["TERM"])
        return true if env.key?("KITTY_WINDOW_ID") || env.key?("WT_SESSION") || env.key?("ALACRITTY_WINDOW_ID")
        return true if env["VTE_VERSION"].to_i >= 5000
        return true if env["KONSOLE_VERSION"].to_i >= 201200

        false
      end

      # Wraps `text` in an OSC 8 hyperlink to `path`, with the line and column
      # as the fragment: "file:///app/pages/thing.tsx#33:9".
      def file_link(text, path:, line: nil, column: nil)
        encoded = path.to_s.b.gsub(%r{[^A-Za-z0-9\-._~/]}) { format("%%%02X", it.ord) }
        fragment = line && "##{[line, column].compact.join(":")}"

        "\e]8;;file://#{encoded}#{fragment}\e\\#{text}\e]8;;\e\\"
      end

      # Colored per line so loggers that prefix each line do not carry the
      # color into their gutter.
      def detail(message, ansi: true)
        return message unless ansi && message

        message.to_s.lines(chomp: true).map { it.empty? ? it : "#{DETAIL}#{it}#{RESET}" }.join("\n")
      end

      def excerpt(source:, line:, column: nil, context: 2, ansi: true, location: nil)
        return nil unless line

        lines = source.to_s.lines
        return nil if lines.empty?

        index = line - 1
        return nil unless index.between?(0, lines.length - 1)

        first = [index - context, 0].max
        last = [index + context, lines.length - 1].min
        width = (last + 1).to_s.length
        gutter = " " * (width + 3)

        rows =
          (first..last).flat_map do |line_index|
            marked = line_index == index
            number = (line_index + 1).to_s.rjust(width)
            code = lines.fetch(line_index).chomp
            formatted =
              if marked
                row = "> #{number} │ #{code}".rstrip
                ansi ? "#{MARKED_LINE}#{row}#{RESET}" : row
              else
                "#{dim("  #{number} │", ansi:)} #{code}".rstrip
              end

            marked ? [formatted, caret_row(width, column, ansi:)].compact : [formatted]
          end

        [
          location ? "#{gutter}#{dim("╭─[", ansi:)}#{location}#{dim("]", ansi:)}" : "#{gutter}#{dim("╭────", ansi:)}",
          *rows,
          "#{gutter}#{dim("╰────", ansi:)}"
        ].join("\n")
      end

      # `text` without color codes or OSC 8 links, as a terminal would show it.
      def strip(text)
        text.to_s.gsub(/\e\[[0-9;]*m|\e\]8;[^\e\a]*(?:\e\\|\a)/, "")
      end

      def dim(text, ansi: true)
        ansi ? "#{DIM}#{text}#{RESET}" : text
      end

      # "    ·       ^", aligned under the offending column of the marked line.
      def caret_row(width, column, ansi: true)
        return nil unless column&.positive?

        "#{" " * (width + 3)}#{dim("·", ansi:)} #{" " * (column - 1)}^"
      end

      # What to try next, one "hint: ..." line per hint.
      def hint_section(hints, ansi: true)
        hints = Array(hints).map(&:to_s).reject(&:empty?)
        return nil if hints.empty?

        hints.map { ansi ? "#{HINT_LABEL}hint:#{RESET} #{HINT}#{it}#{RESET}" : "hint: #{it}" }.join("\n")
      end
    end
  end
end
