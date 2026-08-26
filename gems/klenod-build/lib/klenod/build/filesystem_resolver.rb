# frozen_string_literal: true

require "did_you_mean"

require_relative "errors"

module Klenod
  module Build
    class FilesystemResolver
      MAX_CORRECTIONS = 3

      PathMatch = Data.define(:path, :case_mismatch)

      def initialize(root:, extensions: [], path_prefix: nil)
        @root = Pathname.new(root).expand_path
        @extensions = extensions.freeze
        @path_prefix = path_prefix.to_s
      end

      def resolve(relative_path)
        relative_path = normalize_relative_path(relative_path)
        case_corrections = []

        candidate_paths(relative_path).each do |candidate_path|
          path_matches(candidate_path).each do |match|
            return match.path unless match.case_mismatch

            case_corrections << relative_path_for(match.path)
          end
        end

        unless case_corrections.empty?
          raise ResolveError.new(
            nil,
            unresolved_path: display_path(relative_path),
            reason: :incorrect_case,
            requested_specifier: display_path(relative_path),
            suggestions: case_corrections.uniq.map { display_path(it) }.first(MAX_CORRECTIONS)
          )
        end

        corrections = spelling_corrections(relative_path)
        raise ResolveError.new(
          nil,
          unresolved_path: display_path(relative_path),
          reason: :not_found,
          requested_specifier: display_path(relative_path),
          suggestions: corrections.map { display_path(it) }
        )
      end

      private

      attr_reader :root, :extensions

      def normalize_relative_path(path)
        expanded = root.join(path.to_s).expand_path
        root_path = root.to_s
        expanded_path = expanded.to_s

        unless expanded_path == root_path || expanded_path.start_with?("#{root_path}#{File::SEPARATOR}")
          raise ResolveError.new(
            "Resolved path escapes root: #{path}",
            unresolved_path: path.to_s
          )
        end

        normalize_path(expanded.relative_path_from(root).to_s)
      end

      def candidate_paths(relative_path)
        [relative_path, *extensions.map { |extension| "#{relative_path}#{extension}" }]
      end

      def path_matches(relative_path)
        states = [[root, false]]

        relative_path.split("/").each do |part|
          states =
            states.flat_map do |directory, case_mismatch|
              entries = directory_entries(directory)
              matches = entries.include?(part) ? [part] : entries.select { it.casecmp?(part) }.sort

              matches.map do |entry|
                [directory.join(entry), case_mismatch || entry != part]
              end
            end
          return [] if states.empty?
        end

        states.filter_map do |path, case_mismatch|
          PathMatch.new(path, case_mismatch) if path.file?
        end
      end

      def directory_entries(directory)
        return [] unless directory.directory?

        directory.children.map { it.basename.to_s }
      rescue SystemCallError
        []
      end

      def spelling_corrections(relative_path)
        aliases = spelling_aliases
        matches =
          DidYouMean::TreeSpellChecker
            .new(dictionary: aliases.keys.sort, separator: "/")
            .correct(relative_path)

        matches.flat_map { aliases.fetch(it) }.uniq.first(MAX_CORRECTIONS)
      end

      def spelling_aliases
        source_files.each_with_object({}) do |path, aliases|
          aliases[path] = [path]
          extension = extensions.find { path.end_with?(it) }
          next unless extension

          alias_path = path.delete_suffix(extension)
          aliases[alias_path] ||= []
          aliases[alias_path] << path
        end
      end

      def source_files
        Dir
          .glob("**/*", File::FNM_DOTMATCH, base: root.to_s)
          .select { |path| root.join(path).file? }
          .map { normalize_path(it) }
          .sort
      end

      def display_path(relative_path)
        "#{@path_prefix}#{relative_path}"
      end

      def relative_path_for(path)
        normalize_path(path.relative_path_from(root).to_s)
      end

      def normalize_path(path)
        path.tr("\\", "/")
      end
    end
  end
end
