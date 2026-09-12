# frozen_string_literal: true

require "language_server-protocol"
require "logger"

require_relative "documents"
require_relative "languages"
require_relative "text"
require_relative "version"
require_relative "workspace"

module Klenod
  module LSP
    # A single-threaded Language Server Protocol server over stdio.
    #
    # Frameworks start it with their own build context:
    #
    #   Klenod::LSP::Server.new(context: config.context(mode: :development)).start
    #
    # The server transforms open documents with the context's plugins and
    # publishes the resulting build errors as diagnostics. It never evaluates
    # application code.
    class Server
      Protocol = LanguageServer::Protocol
      Interface = Protocol::Interface
      Constant = Protocol::Constant

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
        "workspace/didChangeConfiguration" => :handle_noop,
        "workspace/didChangeWatchedFiles" => :handle_did_change_watched_files,
        "$/cancelRequest" => :handle_noop,
        "$/setTrace" => :handle_noop
      }.freeze

      def initialize(context:, input: $stdin, output: $stdout, logger: nil)
        @reader = Protocol::Transport::Io::Reader.new(input)
        @writer = Protocol::Transport::Io::Writer.new(output)
        @logger = logger || Logger.new($stderr, progname: "klenod-lsp")
        @workspace = Workspace.new(context: context)
        @documents = Documents.new(@workspace)
        @client_capabilities = {}
        @next_request_id = 0
        @shutdown_requested = false
        @exit_requested = false
      end

      # Runs until the client sends `exit` or closes the input. Returns the
      # exit status the protocol expects: 0 after `shutdown`, 1 otherwise.
      def start
        with_protocol_stdout do
          @reader.read do |message|
            dispatch(message)
            break if @exit_requested
          end
        end

        @shutdown_requested ? 0 : 1
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

      def notify(method_name, params)
        @writer.write(method: method_name, params: params)
      end

      # Server-to-client requests. Their responses arrive without a method
      # and are ignored by dispatch, because nothing here depends on them.
      def request(method_name, params)
        @writer.write(id: "klenod-lsp-#{@next_request_id += 1}", method: method_name, params: params)
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
            code_action_provider: Interface::CodeActionOptions.new(code_action_kinds: [Constant::CodeActionKind::QUICK_FIX])
          ),
          server_info: {name: "klenod", version: VERSION}
        )
      end

      def handle_noop(_message)
        nil
      end

      # Ask the editor to report file changes under the source directory, so
      # diagnostics can follow files created, changed, or removed outside the
      # open documents. Clients without dynamic registration need a static
      # watcher configuration instead.
      def handle_initialized(_message)
        return unless @client_capabilities.dig(:workspace, :didChangeWatchedFiles, :dynamicRegistration)

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

      # Re-analyze the open documents a file change can affect: owners of a
      # changed companion file, documents whose unresolved import may now
      # resolve, and documents importing a deleted file. A document's own
      # file is skipped: the editor already reported that save through didSave.
      def handle_did_change_watched_files(message)
        changes = Array(message.dig(:params, :changes)).filter_map do |change|
          path = @workspace.path_for_uri(change[:uri].to_s)
          path && [path, change[:type]]
        end
        return if changes.empty?

        @workspace.clear_resolver_cache
        changed_paths = changes.map(&:first)
        owner_ids = @workspace.companion_owner_module_ids(changed_paths).map(&:to_s)
        deleted_ids = changes.filter_map { |path, type| @workspace.module_id_for_path(path)&.to_s if type == Constant::FileChangeType::DELETED }

        @documents.each do |document|
          next if changed_paths.include?(document.path)
          next unless Languages.for(document)
          next unless affected_by_change?(document, owner_ids, deleted_ids)

          @documents.invalidate(document.uri)
          publish_diagnostics(document)
        end
      end

      def affected_by_change?(document, owner_ids, deleted_ids)
        return true if owner_ids.include?(document.module_id.to_s)

        analysis = @documents.cached_analysis(document)
        return true unless analysis
        return true unless analysis.resolve_errors.empty?

        analysis.resolved_dependencies.any? { |resolved| deleted_ids.include?(resolved.module_id.to_s) }
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
      end

      def handle_did_change(message)
        params = message[:params]
        change = Array(params[:contentChanges]).last
        return unless change

        document = @documents.change(uri: params.dig(:textDocument, :uri), text: change[:text], version: params.dig(:textDocument, :version))
        publish_diagnostics(document)
      end

      # Companion files may have changed on disk, so the cached analysis is
      # dropped even though the document version did not change.
      def handle_did_save(message)
        document = @documents.fetch(message.dig(:params, :textDocument, :uri))
        return unless document

        @documents.invalidate(document.uri)
        publish_diagnostics(document)
      end

      def handle_did_close(message)
        uri = message.dig(:params, :textDocument, :uri)
        document = @documents.close(uri)
        return unless document && Languages.for(document)

        notify("textDocument/publishDiagnostics", Interface::PublishDiagnosticsParams.new(uri: uri, diagnostics: []))
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
