# frozen_string_literal: true

require "prism"

require "klenod/build/context"

require_relative "analysis"

module Klenod
  module LSP
    # Adapts a Klenod::Build::Context to editor documents.
    #
    # The workspace only transforms and resolves; it never collects records
    # or evaluates application code. That keeps unsaved editor text out of
    # the graph and keeps the server responsive without a file watcher.
    class Workspace
      IMPORT_KIND = :haml_import

      attr_reader :context, :source_dir

      def initialize(context:)
        @context = context
        @graph = context.graph
        @source_dir = File.expand_path(@graph.source_dir.to_s)
      end

      def path_for_uri(uri)
        return nil unless uri.start_with?("file://")

        path = uri.delete_prefix("file://").split("?", 2).first.to_s
        path = path.sub(/\A[^\/]+/, "") unless path.start_with?("/")
        percent_decode(path)
      end

      def uri_for_path(path)
        "file://#{path.split("/", -1).map { |segment| percent_encode(segment) }.join("/")}"
      end

      def module_id_for_uri(uri)
        path = path_for_uri(uri)
        path && module_id_for_path(path)
      end

      def module_id_for_path(path)
        return nil unless path.start_with?("#{source_dir}/")

        Klenod::Build::ModuleId.new("app:/#{path.delete_prefix("#{source_dir}/")}")
      end

      def path_for_module_id(module_id)
        return nil unless module_id.scheme == :app

        @graph.absolute_path(module_id).to_s
      end

      def uri_for_module_id(module_id)
        path = path_for_module_id(module_id)
        path && uri_for_path(path)
      end

      # The Haml plugin's `variables` mapping, e.g. `{global: "@__props"}`.
      # Empty when no Haml plugin is configured or it maps nothing.
      def haml_variables
        plugin = @graph.plugins.find { |candidate| candidate.is_a?(Klenod::Build::Plugins::HamlPlugin::Plugin) }
        plugin&.variables || {}
      end

      def analyze(module_id, source)
        transform = @graph.transform_source(module_id, source)
        resolved_dependencies, resolve_errors = resolve_dependencies(module_id, transform)

        Analysis.new(
          module_id: module_id,
          source: source,
          transform: transform,
          resolved_dependencies: resolved_dependencies,
          build_error: nil,
          ruby_errors: ruby_errors_for(transform),
          resolve_errors: resolve_errors
        )
      rescue Klenod::Build::Error => error
        failed_analysis(module_id, source, error)
      rescue => error
        # Plugins can raise their parser's own errors on half-typed source,
        # e.g. SyntaxTree on an unterminated import string. Report them
        # rather than dropping the document's diagnostics.
        failed_analysis(module_id, source, error)
      end

      def resolve(specifier, importer_id:)
        dependency = Klenod::Build::Dependency.create(specifier: specifier, importer_id: importer_id, kind: IMPORT_KIND)
        @graph.resolve_dependency(dependency).module_id
      rescue Klenod::Build::ResolveError
        nil
      end

      private

      def failed_analysis(module_id, source, error)
        Analysis.new(
          module_id: module_id,
          source: source,
          transform: nil,
          resolved_dependencies: [],
          build_error: error,
          ruby_errors: [],
          resolve_errors: []
        )
      end

      def resolve_dependencies(module_id, transform)
        resolved = []
        errors = []

        transform.dependencies.each do |dependency|
          resolved << @graph.resolve_dependency(dependency)
        rescue Klenod::Build::ResolveError => error
          errors << error.with_resolution_context(dependency: dependency, importer_id: module_id)
        end

        [resolved, errors]
      end

      # Ruby modules are checked against their original source by RubyPlugin,
      # which reports better locations than the generated code would.
      def ruby_errors_for(transform)
        return [] if transform.code.nil?

        Prism.parse(transform.code).errors.map do |error|
          RubyError.new(message: error.message, generated_line: error.location.start_line)
        end
      end

      def percent_decode(value)
        value.gsub(/%[0-9A-Fa-f]{2}/) { |escaped| escaped[1..].hex.chr }.force_encoding(Encoding::UTF_8)
      end

      def percent_encode(segment)
        segment.b.gsub(/[^A-Za-z0-9\-._~!$&'()*+,;=:@]/) { |byte| format("%%%02X", byte.ord) }
      end
    end
  end
end
