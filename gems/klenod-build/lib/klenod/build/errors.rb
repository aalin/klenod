# frozen_string_literal: true

module Klenod
  class Error < StandardError; end unless const_defined?(:Error, false)

  module Build
    class Error < Klenod::Error; end

    class ResolveError < Error
      REASONS = [:incorrect_case, :not_found].freeze

      attr_reader :unresolved_path, :dependency, :importer_id, :reason, :requested_specifier, :suggestions

      def initialize(message = nil, unresolved_path: nil, dependency: nil, importer_id: nil, reason: nil, requested_specifier: nil, suggestions: [])
        @unresolved_path = unresolved_path
        @dependency = dependency
        @importer_id = importer_id
        @reason = reason
        @requested_specifier = requested_specifier
        @suggestions = suggestions.freeze

        super(message || resolution_message)
      end

      def resolution_failure?
        REASONS.include?(reason) && requested_specifier
      end

      def title
        case reason
        when :incorrect_case then "Incorrect import path casing"
        when :not_found then "Module not found"
        else self.class.name
        end
      end

      def source_location
        dependency&.loc
      end

      def imported_by
        if source_location&.line
          "#{display_importer(source_location.path)}:#{source_location.line}"
        else
          display_importer(dependency&.importer_id || importer_id)
        end
      end

      def with_resolution_context(dependency:, importer_id:)
        unless resolution_failure?
          return self if self.dependency

          return self.class.new(
            contextual_message(dependency, importer_id),
            unresolved_path: unresolved_path,
            dependency: dependency,
            importer_id: importer_id
          )
        end

        replacements = suggestions.map { replacement_specifier(it, dependency) }
        self.class.new(
          nil,
          unresolved_path: unresolved_path,
          dependency: dependency,
          importer_id: importer_id,
          reason: reason,
          requested_specifier: dependency.specifier.to_s,
          suggestions: replacements
        )
      end

      def with_path_prefix(prefix)
        return self unless resolution_failure?

        self.class.new(
          nil,
          unresolved_path: unresolved_path,
          dependency: dependency,
          importer_id: importer_id,
          reason: reason,
          requested_specifier: prefixed_path(prefix, requested_specifier),
          suggestions: suggestions.map { prefixed_path(prefix, it) }
        )
      end

      private

      def resolution_message
        requested = requested_specifier.inspect
        case reason
        when :incorrect_case
          suggestion = suggestions.first
          suggestion ? "Incorrect case for #{requested}. Use #{suggestion.inspect}." : "Incorrect case for #{requested}."
        when :not_found
          message = "Could not resolve #{requested}"
          return message if suggestions.empty?

          if suggestions.one?
            "#{message}. Did you mean #{suggestions.first.inspect}?"
          else
            "#{message}. Did you mean #{suggestions.map(&:inspect).join(", ")}?"
          end
        else
          "Could not resolve #{requested}"
        end
      end

      def display_importer(value)
        value&.to_s&.delete_prefix("app:/")
      end

      def contextual_message(dependency, importer_id)
        details = [
          "while resolving #{dependency.specifier.inspect}",
          "for #{importer_id}",
          "from #{dependency.importer_id || "unknown importer"}"
        ]
        details << "kind: #{dependency.kind}" if dependency.kind
        details << "at #{dependency.loc}" if dependency.loc

        "#{message} (#{details.join(", ")})"
      end

      def replacement_specifier(suggestion, dependency)
        canonical = canonical_parts(suggestion)
        return suggestion unless canonical

        requested_path, query = dependency.specifier.to_s.split("?", 2)
        replacement =
          if requested_path.match?(/\A[A-Za-z][A-Za-z0-9+.-]*:/)
            suggestion
          elsif requested_path.start_with?("/")
            "/#{canonical.fetch(:path)}"
          elsif (importer = canonical_parts(dependency.importer_id.to_s)) && importer.fetch(:root) == canonical.fetch(:root)
            relative = Pathname.new(canonical.fetch(:path)).relative_path_from(Pathname.new(File.dirname(importer.fetch(:path)))).to_s
            (requested_path.start_with?("./") && !relative.start_with?(".")) ? "./#{relative}" : relative
          else
            canonical.fetch(:path)
          end

        query ? "#{replacement}?#{query}" : replacement
      rescue ArgumentError
        suggestion
      end

      def canonical_parts(value)
        case value.to_s
        when /\A(?<scheme>[A-Za-z][A-Za-z0-9+.-]*):\/\/(?<host>[^\/]+)\/(?<path>.*)\z/
          {root: "#{$~[:scheme]}://#{$~[:host]}/", path: $~[:path]}
        when /\A(?<scheme>[A-Za-z][A-Za-z0-9+.-]*):\/(?<path>.*)\z/
          {root: "#{$~[:scheme]}:/", path: $~[:path]}
        end
      end

      def prefixed_path(prefix, value)
        return value if value.to_s.match?(/\A[A-Za-z][A-Za-z0-9+.-]*:/)

        "#{prefix}#{value}"
      end
    end

    class DynamicImportError < Error; end
    class UnsupportedFileError < Error; end

    class ImportCycleError < Error
      attr_reader :cycle

      def initialize(cycle)
        @cycle = cycle.freeze
        super("Import cycle detected: #{cycle.join(" -> ")}")
      end
    end
  end
end
