# frozen_string_literal: true

require "language_server-protocol"

require "klenod/build/module_id"

require_relative "diagnostics"
require_relative "languages"

module Klenod
  module LSP
    # Workspace edits that keep imports valid when the editor renames or
    # moves files or folders under the source directory.
    #
    # Importers get their literals rewritten to the new location, and a
    # moved module gets its own relative imports rewritten from its new
    # directory. Each literal keeps its style: root-relative stays
    # root-relative, `./` stays `./`, bare stays bare, and an extension is
    # kept only when the literal had one. Edits are keyed by the files' old
    # URIs because the client applies them before renaming.
    module Renames
      Interface = LanguageServer::Protocol::Interface

      Move = Data.define(:old_path, :new_path) do
        def apply(path)
          return new_path if path == old_path
          return path unless path.start_with?("#{old_path}/")

          new_path + path.delete_prefix(old_path)
        end
      end

      module_function

      def call(files, index, workspace)
        moves = files.filter_map do |old_uri, new_uri|
          old_path = workspace.path_for_uri(old_uri)
          new_path = workspace.path_for_uri(new_uri)
          Move.new(old_path, new_path) if old_path && new_path
        end
        return nil if moves.empty?

        changes = Hash.new { |hash, uri| hash[uri] = [] }
        moves.each do |move|
          moved_module_ids(move, index, workspace).each do |module_id|
            index.ensure_collected(module_id)
            importer_edits(module_id, moves, index, workspace, changes)
            own_edits(module_id, moves, index, workspace, changes)
          end
        end
        return nil if changes.empty?

        sorted = changes.transform_values { |edits| edits.sort_by { |edit| [edit.range.start.line, edit.range.start.character] } }
        Interface::WorkspaceEdit.new(changes: sorted)
      end

      def moved_module_ids(move, index, workspace)
        if File.directory?(move.old_path)
          index.records.keys.select do |module_id|
            path = workspace.path_for_module_id(module_id)
            path&.start_with?("#{move.old_path}/")
          end
        else
          module_id = workspace.module_id_for_path(move.old_path)
          module_id ? [module_id] : []
        end
      end

      def importer_edits(module_id, moves, index, workspace, changes)
        new_target_path = apply_moves(workspace.path_for_module_id(module_id), moves)

        index.dependents(module_id).each do |importer_id|
          record = index.record(importer_id)
          importer_path = record && workspace.path_for_module_id(importer_id)
          next unless importer_path

          lines = record.source.lines(chomp: true)
          importer_new_path = apply_moves(importer_path, moves)
          record.resolved_dependencies.each do |resolved|
            next unless resolved.module_id == module_id

            add_edit(changes, workspace.uri_for_path(importer_path), lines, resolved.dependency.specifier.to_s, importer_new_path, new_target_path, workspace)
          end
        end
      end

      def own_edits(module_id, moves, index, workspace, changes)
        record = index.record(module_id)
        path = record && workspace.path_for_module_id(module_id)
        return unless path

        lines = record.source.lines(chomp: true)
        new_path = apply_moves(path, moves)
        record.resolved_dependencies.each do |resolved|
          specifier = resolved.dependency.specifier.to_s
          next if specifier.start_with?("/") || specifier.match?(Klenod::Build::ModuleId::SCHEME_PATTERN)

          target_path = workspace.path_for_module_id(resolved.module_id)
          next unless target_path

          add_edit(changes, workspace.uri_for_path(path), lines, specifier, new_path, apply_moves(target_path, moves), workspace)
        end
      end

      def add_edit(changes, uri, lines, specifier, importer_path, target_path, workspace)
        replacement = rewrite_specifier(specifier, importer_path, target_path, workspace.source_dir)
        return if replacement == specifier

        syntax = Languages.syntax_for(File.extname(workspace.path_for_uri(uri).to_s))
        Diagnostics.literal_spans(specifier, lines, syntax: syntax).each do |span|
          next if changes[uri].any? { |edit| edit.range.start.line == span.line && edit.range.start.character == span.start_character }

          changes[uri] << Interface::TextEdit.new(range: span.to_range, new_text: replacement)
        end
      end

      def rewrite_specifier(specifier, importer_path, target_path, source_dir)
        path_part, query = specifier.split("?", 2)
        target = File.extname(path_part).empty? ? target_path.delete_suffix(File.extname(target_path)) : target_path

        rewritten =
          if path_part.start_with?("/")
            "/#{Pathname.new(target).relative_path_from(Pathname.new(source_dir))}"
          else
            relative = Pathname.new(target).relative_path_from(Pathname.new(File.dirname(importer_path))).to_s
            if path_part.start_with?("./")
              relative.start_with?("../") ? relative : "./#{relative}"
            else
              relative
            end
          end

        query ? "#{rewritten}?#{query}" : rewritten
      end

      def apply_moves(path, moves)
        moves.reduce(path) { |current, move| move.apply(current) }
      end
    end
  end
end
