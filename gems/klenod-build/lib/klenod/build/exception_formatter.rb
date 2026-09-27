# frozen_string_literal: true

require "klenod/runtime/backtrace_rewriter"

require_relative "source_excerpt"

module Klenod
  module Build
    # A runtime exception as a development report, in the same shape as a
    # SourceError: the class and message, an excerpt of the first frame that
    # has source, then the frames.
    #
    #   × NameError: undefined local variable or method 'x'
    #
    #       ╭─[app:/routes/page.haml:4]
    #     3 │ %h1 Hello
    #   > 4 │ %p= x
    #       ╰────
    #     at app:/routes/page.haml:4:in 'render'
    #     at /gems/rack/lib/rack.rb:12:in 'call'
    #
    # Rewriting lives in Klenod::Runtime::BacktraceRewriter, so a production
    # application keeps corrected backtraces without loading any of this.
    module ExceptionFormatter
      Entry = Runtime::BacktraceRewriter::ParsedBacktraceEntry

      module_function

      # `mods` maps module IDs to evaluated modules, as Graph#mods does. The
      # error is rewritten in place.
      def format(error, mods: {}, ansi: true, links: ansi && SourceExcerpt.hyperlinks?)
        rewriter = Runtime::BacktraceRewriter.new(mods)
        rewriter.rewrite_exception(error)
        module_ids = mods.values.select { it.respond_to?(:eval_path) }.to_h { [it.eval_path.to_s, it.path.to_s] }
        frames = Array(error.backtrace).map { Entry.parse(it) || it.to_s }

        [
          SourceExcerpt.header(error.class.name, error.message, ansi:),
          [
            excerpt(frames, rewriter, module_ids, ansi:, links:),
            *frames.map { "  #{frame(it, module_ids, ansi:, links:)}" }
          ].compact.join("\n")
        ].reject(&:empty?).join("\n\n")
      end

      # The first frame the rewriter has original source for, boxed.
      def excerpt(frames, rewriter, module_ids, ansi:, links:)
        frames.grep(Entry).each do |entry|
          source = rewriter.source_for(entry.file)
          next unless source

          location = location(entry, module_ids, ansi:, links:)
          excerpt = SourceExcerpt.excerpt(source:, line: entry.line, ansi:, location:)
          return excerpt if excerpt
        end

        nil
      end

      # "at app:/routes/page.haml:4:in 'render'". Frames outside the graph are
      # dimmed so the application's own frames stand out.
      def frame(entry, module_ids, ansi:, links:)
        return SourceExcerpt.dim("at #{entry}", ansi:) unless entry.is_a?(Entry) && module_ids.key?(entry.file)

        "#{SourceExcerpt.dim("at", ansi:)} #{location(entry, module_ids, ansi:, links:)}#{SourceExcerpt.dim(":in '#{entry.description}'", ansi:)}"
      end

      # Graph modules are named by module ID and linked to the file they were
      # evaluated from.
      def location(entry, module_ids, ansi:, links:)
        SourceExcerpt.styled_location(
          module_id: module_ids.fetch(entry.file, entry.file),
          line: entry.line,
          path: entry.file,
          ansi:,
          links:
        )
      end
    end
  end
end
