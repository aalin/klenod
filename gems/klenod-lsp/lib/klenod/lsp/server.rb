# frozen_string_literal: true

require "async"
require "json"
require "language_server-protocol"
require "logger"

require_relative "documents"
require_relative "graph_index"
require_relative "languages"
require_relative "renames"
require_relative "symbols"
require_relative "text"
require_relative "version"
require_relative "workspace"

module Klenod
  module LSP
    # A single-threaded Language Server Protocol server over stdio.
    #
    # Frameworks start it with their own build context, collected in
    # analysis mode so plugins skip asset work:
    #
    #   context = config.context(mode: :development, analysis: true)
    #   Klenod::LSP::Server.new(context: context, entrypoints: config.entrypoints).start
    #
    # Open documents are transformed with the context's plugins and their
    # build errors published as diagnostics. The same context also holds a
    # collected module graph for cross-file features, filled in the
    # background. Nothing is ever evaluated.
    class Server
      Protocol = LanguageServer::Protocol
      Interface = Protocol::Interface
      Constant = Protocol::Constant

      DIAGNOSTICS_DEBOUNCE = 0.1
      COLLECTION_DEBOUNCE = 0.25

      HANDLERS = {
        "initialize" => :handle_initialize,
        "initialized" => :handle_initialized,
        "shutdown" => :handle_shutdown,
        "exit" => :handle_exit,
        "textDocument/didOpen" => :handle_did_open,
        "textDocument/didChange" => :handle_did_change,
        "textDocument/didSave" => :handle_did_save,
        "textDocument/didClose" => :handle_did_close,
        "textDocument/definition" => :handle_definition,
        "textDocument/hover" => :handle_hover,
        "textDocument/completion" => :handle_completion,
        "textDocument/documentLink" => :handle_document_link,
        "textDocument/codeAction" => :handle_code_action,
        "textDocument/references" => :handle_references,
        "workspace/willRenameFiles" => :handle_will_rename_files,
        "textDocument/documentSymbol" => :handle_document_symbol,
        "workspace/symbol" => :handle_workspace_symbol,
        "workspace/didChangeConfiguration" => :handle_noop,
        "workspace/didChangeWatchedFiles" => :handle_did_change_watched_files,
        "$/cancelRequest" => :handle_noop,
        "$/setTrace" => :handle_noop
      }.freeze

      # Reports background collection through window/workDoneProgress when
      # the client supports it, and stays silent otherwise.
      class WorkDoneProgress
        TOKEN = "klenod-lsp.graph-index"

        def initialize(server, enabled:)
          @server = server
          @enabled = enabled
        end

        def begin(total)
          return unless @enabled

          @server.request("window/workDoneProgress/create", Interface::WorkDoneProgressCreateParams.new(token: TOKEN))
          notify(Interface::WorkDoneProgressBegin.new(kind: "begin", title: "Klenod: indexing modules", message: "0 of #{total}", percentage: 0))
        end

        def report(done, total)
          return unless @enabled

          percentage = total.zero? ? 100 : (done * 100 / total)
          notify(Interface::WorkDoneProgressReport.new(kind: "report", message: "#{done} of #{total}", percentage: percentage))
        end

        def finish
          return unless @enabled

          notify(Interface::WorkDoneProgressEnd.new(kind: "end", message: "Klenod: modules indexed"))
        end

        private

        def notify(value)
          @server.notify("$/progress", Interface::ProgressParams.new(token: TOKEN, value: value))
        end
      end

      def initialize(context:, entrypoints: [], input: $stdin, output: $stdout, logger: nil)
        @reader = Protocol::Transport::Io::Reader.new(input)
        @writer = Protocol::Transport::Io::Writer.new(output)
        @logger = logger || Logger.new($stderr, progname: "klenod-lsp")
        @workspace = Workspace.new(context: context)
        @documents = Documents.new(@workspace)
        @index = GraphIndex.new(workspace: @workspace, entrypoints: entrypoints, logger: @logger)
        @pending_collections = {}
        @closed_diagnostics = {}
        @client_capabilities = {}
        @next_request_id = 0
        @shutdown_requested = false
        @exit_requested = false
      end

      # Runs until the client sends `exit` or closes the input. Returns the
      # exit status the protocol expects: 0 after `shutdown`, 1 otherwise.
      #
      # Everything runs inside one Async reactor: reading the client is
      # fiber-aware, and background collection is a task in the same
      # reactor, so no locking is needed around the graph.
      def start
        with_protocol_stdout do
          Sync do |task|
            @task = task
            @reader.read do |message|
              dispatch(message)
              break if @exit_requested
            end
          ensure
            @pending_collections.each_value(&:stop)
            @index.stop
          end
        end

        @shutdown_requested ? 0 : 1
      end

      def notify(method_name, params)
        @writer.write(method: method_name, params: params)
      end

      # Server-to-client requests. Their responses arrive without a method
      # and are ignored by dispatch, because nothing here depends on them.
      def request(method_name, params)
        @writer.write(id: "klenod-lsp-#{@next_request_id += 1}", method: method_name, params: params)
      end

      private

      # Plugins may print while transforming. The protocol stream is the
      # writer's IO, so anything written to $stdout meanwhile goes to stderr,
      # which editors show in their language server log.
      def with_protocol_stdout
        previous_stdout = $stdout
        $stdout = $stderr
        yield
      ensure
        $stdout = previous_stdout
      end

      def dispatch(message)
        method_name = message[:method]
        return unless method_name

        handler = HANDLERS[method_name]
        if handler
          result = send(handler, message)
          reply(message, result) if request?(message)
        elsif request?(message)
          reply_error(message, Constant::ErrorCodes::METHOD_NOT_FOUND, "Unsupported method: #{method_name}")
        else
          @logger.debug { "Ignoring notification #{method_name}" }
        end
      rescue => error
        @logger.error { "#{error.class}: #{error.message}\n#{Array(error.backtrace).join("\n")}" }
        reply_error(message, Constant::ErrorCodes::INTERNAL_ERROR, "#{error.class}: #{error.message}") if request?(message)
      end

      def request?(message)
        message.key?(:id)
      end

      def reply(message, result)
        @writer.write(id: message[:id], result: result)
      end

      def reply_error(message, code, text)
        @writer.write(id: message[:id], error: Interface::ResponseError.new(code: code, message: text))
      end

      def handle_initialize(message)
        @client_capabilities = message.dig(:params, :capabilities) || {}

        Interface::InitializeResult.new(
          capabilities: Interface::ServerCapabilities.new(
            text_document_sync: Interface::TextDocumentSyncOptions.new(
              open_close: true,
              change: Constant::TextDocumentSyncKind::FULL,
              save: true
            ),
            definition_provider: true,
            hover_provider: true,
            completion_provider: Interface::CompletionOptions.new(trigger_characters: ["%", "/", "\"", "'"]),
            document_link_provider: Interface::DocumentLinkOptions.new,
            code_action_provider: Interface::CodeActionOptions.new(code_action_kinds: [Constant::CodeActionKind::QUICK_FIX]),
            references_provider: true,
            document_symbol_provider: true,
            workspace_symbol_provider: true,
            workspace: {
              fileOperations: Interface::FileOperationOptions.new(
                will_rename: Interface::FileOperationRegistrationOptions.new(
                  filters: [
                    Interface::FileOperationFilter.new(
                      scheme: "file",
                      pattern: Interface::FileOperationPattern.new(glob: File.join(@workspace.source_dir, "**"))
                    )
                  ]
                )
              )
            }
          ),
          server_info: {name: "klenod", version: VERSION}
        )
      end

      def handle_noop(_message)
        nil
      end

      # Ask the editor to report file changes under the source directory so
      # the graph and diagnostics follow files created, changed, or removed
      # outside the open documents, then start indexing in the background.
      # Clients without dynamic registration need a static watcher
      # configuration instead.
      def handle_initialized(_message)
        register_file_watchers if @client_capabilities.dig(:workspace, :didChangeWatchedFiles, :dynamicRegistration)
        progress_supported = @client_capabilities.dig(:window, :workDoneProgress) == true
        @index.start(@task, progress: WorkDoneProgress.new(self, enabled: progress_supported)) { publish_workspace_diagnostics }
      end

      def register_file_watchers
        request(
          "client/registerCapability",
          Interface::RegistrationParams.new(
            registrations: [
              Interface::Registration.new(
                id: "klenod-lsp.watched-files",
                method: "workspace/didChangeWatchedFiles",
                register_options: Interface::DidChangeWatchedFilesRegistrationOptions.new(
                  watchers: [Interface::FileSystemWatcher.new(glob_pattern: File.join(@workspace.source_dir, "**", "*"))]
                )
              )
            ]
          )
        )
      end

      # Changes on disk go through the build's invalidation, which keeps the
      # graph's records, resolver cache, and companion ownership current.
      # Every open document whose record may have changed is re-analyzed. A
      # document's own file is skipped: the editor already reported that
      # save through didSave.
      def handle_did_change_watched_files(message)
        changed_paths = []
        removed_paths = []
        Array(message.dig(:params, :changes)).each do |change|
          path = @workspace.path_for_uri(change[:uri].to_s)
          next unless path

          if change[:type] == Constant::FileChangeType::DELETED
            removed_paths << path
          else
            changed_paths << path
          end
        end
        return if changed_paths.empty? && removed_paths.empty?

        affected = @index.invalidate(changed_paths, removed_paths)
        own_paths = changed_paths + removed_paths

        @documents.each do |document|
          next if own_paths.include?(document.path)
          next unless Languages.for(document)
          next unless affected.include?(document.module_id.to_s)

          @documents.invalidate(document.uri)
          publish_diagnostics(document)
        end
        publish_workspace_diagnostics
      end

      # Modules the index could not collect get diagnostics even while
      # closed, so a rename or deletion that breaks importers shows up in the
      # editor's problem list. Open documents publish their own; a module
      # that recovers has its diagnostics cleared.
      def publish_workspace_diagnostics
        current = {}
        @index.failed.each_key do |module_id_string|
          module_id = Klenod::Build::ModuleId.new(module_id_string)
          next unless GraphIndex::ROOT_EXTENSIONS.include?(module_id.extname)

          path = @workspace.path_for_module_id(module_id)
          next unless path && File.file?(path)

          uri = @workspace.uri_for_path(path)
          next if @documents.fetch(uri)

          document = Document.new(uri: uri, path: path, module_id: module_id, text: File.read(path), version: nil)
          language = Languages.for(document)
          next unless language

          diagnostics = language.diagnostics(@workspace.analyze(module_id, document.text))
          current[uri] = diagnostics unless diagnostics.empty?
        end

        (@closed_diagnostics.keys - current.keys).each do |uri|
          notify("textDocument/publishDiagnostics", Interface::PublishDiagnosticsParams.new(uri: uri, diagnostics: []))
        end
        current.each do |uri, diagnostics|
          next if @closed_diagnostics[uri] == JSON.generate(diagnostics)

          notify("textDocument/publishDiagnostics", Interface::PublishDiagnosticsParams.new(uri: uri, diagnostics: diagnostics))
        end
        @closed_diagnostics = current.transform_values { |diagnostics| JSON.generate(diagnostics) }
      end

      def handle_shutdown(_message)
        @shutdown_requested = true
        nil
      end

      def handle_exit(_message)
        @exit_requested = true
      end

      def handle_did_open(message)
        text_document = message.dig(:params, :textDocument)
        document = @documents.open(uri: text_document[:uri], text: text_document[:text], version: text_document[:version])
        publish_diagnostics(document)
        overlay(document)
        collect_document(document)
      end

      # Editors send a change per keystroke; diagnostics wait for a short
      # pause and the graph record for a slightly longer one. Requests that
      # arrive meanwhile analyze the current text on demand.
      def handle_did_change(message)
        params = message[:params]
        change = Array(params[:contentChanges]).last
        return unless change

        document = @documents.change(uri: params.dig(:textDocument, :uri), text: change[:text], version: params.dig(:textDocument, :version))
        return unless Languages.for(document)

        @pending_collections.delete(document.uri)&.stop
        @pending_collections[document.uri] =
          @task.async do |task|
            task.sleep(DIAGNOSTICS_DEBOUNCE)
            publish_diagnostics(document)
            overlay(document)
            task.sleep(COLLECTION_DEBOUNCE - DIAGNOSTICS_DEBOUNCE)
            @pending_collections.delete(document.uri)
            @index.ensure_collected(document.module_id)
          end
      end

      # Companion files may have changed on disk, so the cached analysis is
      # dropped even though the document version did not change.
      def handle_did_save(message)
        document = @documents.fetch(message.dig(:params, :textDocument, :uri))
        return unless document

        @documents.invalidate(document.uri)
        publish_diagnostics(document)
        collect_document(document)
      end

      # The record follows disk again once the editor lets go of the buffer.
      def handle_did_close(message)
        uri = message.dig(:params, :textDocument, :uri)
        document = @documents.close(uri)
        return unless document && Languages.for(document)

        @pending_collections.delete(uri)&.stop
        @workspace.context.graph.clear_source_override(document.module_id)
        collect_document(document)
        notify("textDocument/publishDiagnostics", Interface::PublishDiagnosticsParams.new(uri: uri, diagnostics: []))
        publish_workspace_diagnostics
      end

      # The graph reads open documents from their buffers rather than disk,
      # and reuses the diagnostics transform when the buffer had no errors so
      # collection does not transform the same text twice.
      def overlay(document)
        return unless Languages.for(document)

        analysis = @documents.cached_analysis(document)
        transform = analysis&.transform if analysis && analysis.build_error.nil? && analysis.resolve_errors.empty?
        @workspace.context.graph.override_source(document.module_id, document.text, transform: transform)
      end

      def collect_document(document)
        return unless Languages.for(document)

        @pending_collections.delete(document.uri)&.stop
        @index.ensure_collected(document.module_id)
      end

      def handle_definition(message)
        with_position(message) { |language, analysis, position| language.definition(analysis, position, @workspace) }
      end

      def handle_hover(message)
        with_position(message) { |language, analysis, position| language.hover(analysis, position, @workspace) }
      end

      def handle_completion(message)
        with_position(message) { |language, analysis, position| language.completion(analysis, position, @workspace) }
      end

      def handle_references(message)
        with_position(message) do |language, analysis, position|
          include_declaration = message.dig(:params, :context, :includeDeclaration) == true
          language.references(analysis, position, @workspace, @index, include_declaration: include_declaration)
        end
      end

      # The editor asks before renaming or moving files, and applies the
      # returned edits first; the watched-file events that follow bring the
      # graph up to date.
      def handle_will_rename_files(message)
        files = Array(message.dig(:params, :files)).map { |file| [file[:oldUri].to_s, file[:newUri].to_s] }
        Renames.call(files, @index, @workspace)
      end

      def handle_document_symbol(message)
        with_document(message) { |language, analysis| language.document_symbols(analysis) }
      end

      def handle_workspace_symbol(message)
        Symbols.workspace_symbols(message.dig(:params, :query), @index, @workspace)
      end

      def handle_document_link(message)
        with_document(message) { |language, analysis| language.document_links(analysis, @workspace) }
      end

      def handle_code_action(message)
        with_document(message) do |language, analysis|
          range = message.dig(:params, :range)
          language.code_actions(analysis, range.dig(:start, :line)..range.dig(:end, :line), @workspace)
        end
      end

      # Document requests share the same shape: nothing for documents the
      # server does not handle, otherwise the language handler answers from
      # the document's analysis.
      def with_document(message)
        document = @documents.fetch(message.dig(:params, :textDocument, :uri))
        language = document && Languages.for(document)
        return nil unless language

        yield language, @documents.analysis_for(document)
      end

      def with_position(message)
        with_document(message) do |language, analysis|
          params = message[:params]
          position = Text::Position.new(line: params.dig(:position, :line), character: params.dig(:position, :character))
          yield language, analysis, position
        end
      end

      def publish_diagnostics(document)
        language = Languages.for(document)
        return unless language

        diagnostics = language.diagnostics(@documents.analysis_for(document))
        notify(
          "textDocument/publishDiagnostics",
          Interface::PublishDiagnosticsParams.new(uri: document.uri, version: document.version, diagnostics: diagnostics)
        )
      end
    end
  end
end
