# frozen_string_literal: true

module Klenod
  module LSP
    Document = Data.define(:uri, :path, :module_id, :text, :version) do
      def lines
        text.lines(chomp: true)
      end

      def extname
        path ? File.extname(path) : ""
      end
    end

    # Open editor documents, synchronized with full text on every change, and
    # the analysis computed for each document version.
    class Documents
      def initialize(workspace)
        @workspace = workspace
        @documents = {}
        @analyses = {}
      end

      def open(uri:, text:, version:)
        document =
          Document.new(
            uri: uri,
            path: @workspace.path_for_uri(uri),
            module_id: @workspace.module_id_for_uri(uri),
            text: text,
            version: version
          )
        @documents[uri] = document
      end

      def change(uri:, text:, version:)
        existing = @documents[uri]
        return self.open(uri: uri, text: text, version: version) unless existing

        @documents[uri] = existing.with(text: text, version: version)
      end

      def close(uri)
        @analyses.delete(uri)
        @documents.delete(uri)
      end

      def fetch(uri)
        @documents[uri]
      end

      def invalidate(uri)
        @analyses.delete(uri)
      end

      def analysis_for(document)
        cached_version, cached = @analyses[document.uri]
        return cached if cached && cached_version == document.version

        analysis = @workspace.analyze(document.module_id, document.text)
        @analyses[document.uri] = [document.version, analysis]
        analysis
      end
    end
  end
end
