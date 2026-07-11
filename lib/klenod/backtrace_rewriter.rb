# frozen_string_literal: true

#
# Copyright Andrés Alin <andreas.alin@gmail.com>
# License: AGPL-3.0

module Klenod
  class BacktraceRewriter
    class BacktraceString < String
      attr_reader :parsed_backtrace_entry

      def initialize(entry)
        super(entry.to_s)
        @parsed_backtrace_entry = entry
      end
    end

    ParsedBacktraceEntry =
      Data.define(:file, :line, :description) do
        def self.parse(line)
          case line
          in BacktraceString
            line.parsed_backtrace_entry
          in /\A(?<file>.*):(?<line>\d+):in [`'](?<description>.*)'\z/
            new($~[:file], $~[:line].to_i, $~[:description])
          end
        end

        def to_s
          "#{file}:#{line}:in `#{description.sub(/^Mayu::Modules::Registry::.+::/, "")}'"
        end

        def to_backtrace_string
          BacktraceString.new(self)
        end
      end

    def initialize(mods)
      @source_maps = source_maps_for(mods)
      @source_map_cache = Hash.new { |h, path| h[path] = @source_maps[path] }
    end

    def format_exception(e, source_path: nil)
      reset = "\e[0;48;5;52m"
      rewrite_exception(e)
      sources = format_sources(e.backtrace)

      [
        "\e[1;31;47m ERROR \e[3;31;47m #{e.class.name}: #{e.message} #{reset}",
        "\e[1;34mBacktrace:#{reset}",
        e
          .backtrace
          .map do |line|
            if line in BacktraceString
              format(
                "#{reset}\e[2mfrom #{reset}\e[1m%<file>s:%<line>d#{reset}\e[2m:in `#{reset}\e[1m%<description>s#{reset}\e[2m`#{reset}",
                line.parsed_backtrace_entry.to_h
              )
            else
              "from #{line}"
            end
          end
          .join("\n"),
        formatted_sources(sources, reset)
      ].compact.join("\n") + "\e[0m"
    end

    def rewrite_exception(e)
      e.set_backtrace(rewrite_backtrace(e.backtrace))
    end

    def rewrite_backtrace(backtrace)
      backtrace.map do |line|
        if (entry = ParsedBacktraceEntry.parse(line))
          rewrite_backtrace_entry(entry).to_backtrace_string
        else
          line
        end
      end
    end

    private

    def formatted_sources(sources, reset)
      return nil if sources.empty?

      [
        "\e[1;34mSources:#{reset}",
        sources
          .map do |file, formatted_source|
            "\e[1m#{file}\e[0m\n#{formatted_source}"
          end
          .join("\n")
      ].join("\n")
    end

    def source_maps_for(mods)
      mods.each_with_object({}) do |(key, mod), index|
        next unless mod.respond_to?(:source_map)

        source_map = mod.source_map
        next unless source_map

        index[key.to_s] = source_map
        index[mod.path.to_s] = source_map if mod.respond_to?(:path)
        index[mod.eval_path.to_s] = source_map if mod.respond_to?(:eval_path)
      end
    end

    def rewrite_backtrace_entry(entry)
      if (original_line_no = find_original_line_no(entry.file, entry.line))
        entry.with(line: original_line_no)
      else
        entry
      end
    end

    def find_original_line_no(file, line_no)
      @source_map_cache[file]&.find_original_line_no(line_no)
    end

    def format_sources(backtrace)
      backtrace
        .select { |line| line.is_a?(BacktraceString) }
        .map(&:parsed_backtrace_entry)
        .group_by(&:file)
        .map do |file, entries|
          if (source_map = @source_map_cache[file])
            [file, format_source(source_map.input, entries.map(&:line))]
          end
        end
        .compact
        .to_h
    end

    def format_source(source, interesting_lines)
      ranges =
        merge_overlapping_ranges(interesting_lines.map { (it - 2)..(it + 2) })
      lines = source.each_line.to_a

      ranges
        .map do |range|
          range
            .map do |i|
              next if i < 0
              str = format("%3d: %s", i, lines[i - 1].chomp)
              interesting_lines.include?(i) ? "\e[1;31m#{str}\e[0m" : str
            end
            .compact
            .join("\n")
        end
        .join("\n\e[37;44m ... \e[0m\n")
    end

    def merge_overlapping_ranges(ranges)
      ranges.each_with_object([]) do |range, merged|
        if (idx = merged.find_index { |r| r.overlap?(range) })
          overlapping = merged[idx]
          merged[idx] = [overlapping.begin, range.begin].min..[
            overlapping.end,
            range.end
          ].max
        else
          merged << range
        end
      end
    end
  end
end
