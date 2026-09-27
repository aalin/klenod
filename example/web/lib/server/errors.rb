# frozen_string_literal: true

require "klenod/build/exception_formatter"
require "klenod/build/resolution_error_formatter"
require "klenod/build/source_excerpt"

require_relative "formatting"

module Example
  module Server
    module ServerErrors
      module_function

      def format_exception(error, context)
        format_build_error(error, context) ||
          Klenod::Build::ExceptionFormatter.format(error, mods: mods(context), ansi: ansi?)
      end

      def format_update_error(module_id, error, context)
        format_build_error(error, context) ||
          [
            "#{module_id}: #{error.class}",
            error.message,
            source_context_for_update_error(module_id, error, context)
          ].compact.join("\n\n")
      end

      # A SourceError renders its own report, and a resolution failure lists
      # the import and the files it could have meant.
      def format_build_error(error, context)
        if parse_error?(error)
          ansi? ? error.message : ServerFormatting.strip_ansi(error.message)
        elsif resolution_error?(error)
          Klenod::Build::ResolutionErrorFormatter.format(
            error,
            source_root: source_root(context),
            source_context: source_context_for_resolution_error(error, context),
            ansi: ansi?
          )
        end
      end

      def mods(context)
        context.respond_to?(:graph) ? context.graph.mods : {}
      end

      def resolution_error?(error)
        error.is_a?(Klenod::Build::ResolveError) && error.resolution_failure?
      end

      def parse_error?(error)
        error.is_a?(Klenod::Build::SourceError)
      end

      def source_root(context)
        context.graph.source_dir if context&.respond_to?(:graph)
      end

      def ansi?
        !ENV.key?("NO_COLOR")
      end

      def source_context_for_resolution_error(error, context)
        location = error.source_location
        return nil unless location&.line && context&.respond_to?(:graph)

        module_id = Klenod::Build::ModuleId.parse(location.path)
        source_path = context.graph.absolute_path(module_id)
        return nil unless source_path.file?

        source_excerpt(source_path.read, location.line)
      rescue Klenod::Build::ResolveError, ArgumentError
        nil
      end

      def source_context_for_update_error(module_id, error, context)
        # A SourceError renders its own excerpt into its message.
        return nil if parse_error?(error)
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
        Klenod::Build::SourceExcerpt.excerpt(source: source, line: line, ansi: ansi?)
      end
    end
  end
end
