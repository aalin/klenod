# frozen_string_literal: true

require "fileutils"
require "json"
require "stringio"
require "tmpdir"

require_relative "__test__/support"

class Klenod::LSP::Server::Test < Minitest::Test
  include Klenod::LSP::TestSupport

  # Drives a server over pipes the way an editor would, one message at a time.
  class Client
    attr_reader :thread

    def initialize(server_input, server_output, status)
      @input = server_input
      @output = server_output
      @status = status
      @next_id = 0
    end

    def request(method, params = {})
      id = (@next_id += 1)
      send(id: id, method: method, params: params)
      read
    end

    def notify(method, params = {})
      send(method: method, params: params)
    end

    def read
      header = @output.gets("\r\n\r\n") or raise "server closed its output"
      length = header[/Content-Length: (\d+)/i, 1].to_i
      JSON.parse(@output.read(length), symbolize_names: true)
    end

    def respond(id, result: nil)
      send(id: id, result: result)
    end

    def exit_status
      @status.value
    end

    private

    def send(message)
      body = JSON.generate(message.merge(jsonrpc: "2.0"))
      @input.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
      @input.flush
    end
  end

  def setup
    @page_uri = fixture_uri("pages/Page.haml")
    @page_source = fixture_source("pages/Page.haml")
    @stderr = StringIO.new
  end

  def test_initialize_advertises_sync_and_definition
    with_server do |client|
      result = client.request("initialize", capabilities: {}).fetch(:result)

      assert_equal({openClose: true, change: 1, save: true}, result.dig(:capabilities, :textDocumentSync))
      assert_equal(true, result.dig(:capabilities, :definitionProvider))
      assert_equal(true, result.dig(:capabilities, :hoverProvider))
      assert_equal(["%", "/", "\"", "'"], result.dig(:capabilities, :completionProvider, :triggerCharacters))
      assert_equal({}, result.dig(:capabilities, :documentLinkProvider))
      assert_equal({codeActionKinds: ["quickfix"]}, result.dig(:capabilities, :codeActionProvider))
      assert_equal(true, result.dig(:capabilities, :referencesProvider))
      assert_equal("klenod", result.dig(:serverInfo, :name))
    end
  end

  def test_hover_returns_markdown_for_the_component_under_the_cursor
    with_server do |client|
      client.notify("textDocument/didOpen", textDocument: {uri: @page_uri, languageId: "haml", version: 1, text: @page_source})
      client.read

      result = client.request("textDocument/hover", textDocument: {uri: @page_uri}, position: {line: 5, character: 4}).fetch(:result)

      assert_equal("markdown", result.dig(:contents, :kind))
      assert_includes(result.dig(:contents, :value), "app:/components/Details.haml")
      assert_equal({line: 5, character: 3}, result.dig(:range, :start))
    end
  end

  def test_completion_lists_bound_components
    with_server do |client|
      client.notify("textDocument/didOpen", textDocument: {uri: @page_uri, languageId: "haml", version: 1, text: @page_source})
      client.read

      result = client.request("textDocument/completion", textDocument: {uri: @page_uri}, position: {line: 5, character: 5}).fetch(:result)

      assert_equal(false, result[:isIncomplete])
      assert_equal(["Details"], result[:items].map { |item| item[:label] })
      assert_equal({range: {start: {line: 5, character: 3}, end: {line: 5, character: 5}}, newText: "Details"}, result.dig(:items, 0, :textEdit))
    end
  end

  def test_open_and_change_publish_diagnostics
    with_server do |client|
      client.notify("textDocument/didOpen", textDocument: {uri: @page_uri, languageId: "haml", version: 1, text: @page_source})
      published = client.read

      assert_equal("textDocument/publishDiagnostics", published[:method])
      assert_equal(@page_uri, published.dig(:params, :uri))
      assert_equal(1, published.dig(:params, :version))
      assert_empty(published.dig(:params, :diagnostics))

      broken = @page_source.sub("/components/Details", "/components/Detials")
      client.notify("textDocument/didChange", textDocument: {uri: @page_uri, version: 2}, contentChanges: [{text: broken}])
      published = client.read

      assert_equal(2, published.dig(:params, :version))
      assert_includes(published.dig(:params, :diagnostics, 0, :message), "Did you mean")

      client.notify("textDocument/didClose", textDocument: {uri: @page_uri})
      published = client.read

      assert_empty(published.dig(:params, :diagnostics))
    end
  end

  def test_definition_returns_the_component_file
    with_server do |client|
      client.notify("textDocument/didOpen", textDocument: {uri: @page_uri, languageId: "haml", version: 1, text: @page_source})
      client.read

      result = client.request("textDocument/definition", textDocument: {uri: @page_uri}, position: {line: 5, character: 4}).fetch(:result)

      assert_equal(fixture_uri("components/Details.haml"), result[:uri])
    end
  end

  def test_document_links_are_returned_for_open_documents
    with_server do |client|
      client.notify("textDocument/didOpen", textDocument: {uri: @page_uri, languageId: "haml", version: 1, text: @page_source})
      client.read

      result = client.request("textDocument/documentLink", textDocument: {uri: @page_uri}).fetch(:result)

      assert_equal(2, result.length)
      assert_equal(fixture_uri("components/Details.haml"), result.dig(0, :target))
      assert_equal({line: 1, character: 20}, result.dig(0, :range, :start))
    end
  end

  def test_code_actions_return_quick_fixes_for_the_diagnostics_in_range
    with_server do |client|
      broken = @page_source.sub("/components/Details", "/components/Detials")
      client.notify("textDocument/didOpen", textDocument: {uri: @page_uri, languageId: "haml", version: 1, text: broken})
      published = client.read
      diagnostic = published.dig(:params, :diagnostics, 0)

      result = client.request(
        "textDocument/codeAction",
        textDocument: {uri: @page_uri},
        range: diagnostic[:range],
        context: {diagnostics: [diagnostic]}
      ).fetch(:result)

      assert_equal(["Replace with \"/components/Details.haml\""], result.map { |action| action[:title] })
      assert_equal("/components/Details.haml", result.dig(0, :edit, :changes, @page_uri.to_sym, 0, :newText))
      assert_equal(diagnostic[:range], result.dig(0, :edit, :changes, @page_uri.to_sym, 0, :range))
    end
  end

  def test_watched_file_changes_refresh_other_open_documents
    Dir.mktmpdir do |dir|
      FileUtils.cp_r("#{Klenod::LSP::TestSupport::FIXTURE_SOURCE_DIR}/.", dir)
      page_uri = "file://#{dir}/pages/Page.haml"

      with_server(source_dir: dir) do |client|
        client.request("initialize", capabilities: {workspace: {didChangeWatchedFiles: {dynamicRegistration: true}}})
        client.notify("initialized")
        registration = client.read

        assert_equal("client/registerCapability", registration[:method])
        assert_equal("workspace/didChangeWatchedFiles", registration.dig(:params, :registrations, 0, :method))
        assert_equal("#{dir}/**/*", registration.dig(:params, :registrations, 0, :registerOptions, :watchers, 0, :globPattern))
        client.respond(registration[:id])

        broken = @page_source.sub("./layout", "./sidebar")
        client.notify("textDocument/didOpen", textDocument: {uri: page_uri, languageId: "haml", version: 1, text: broken})
        assert_includes(client.read.dig(:params, :diagnostics, 0, :message), "Could not resolve")

        File.write("#{dir}/pages/sidebar.rb", "Default = 1\n")
        client.notify("workspace/didChangeWatchedFiles", changes: [{uri: "file://#{dir}/pages/sidebar.rb", type: 1}])
        published = client.read

        assert_equal(page_uri, published.dig(:params, :uri))
        assert_empty(published.dig(:params, :diagnostics))
      end
    end
  end

  def test_watched_companion_changes_refresh_the_owning_document
    Dir.mktmpdir do |dir|
      FileUtils.cp_r("#{Klenod::LSP::TestSupport::FIXTURE_SOURCE_DIR}/.", dir)
      page_uri = "file://#{dir}/pages/Page.haml"

      with_server(source_dir: dir) do |client|
        client.notify("textDocument/didOpen", textDocument: {uri: page_uri, languageId: "haml", version: 1, text: @page_source})
        assert_empty(client.read.dig(:params, :diagnostics))

        File.write("#{dir}/pages/Page.intl.en.toml", "title = \"unterminated\n")
        client.notify("workspace/didChangeWatchedFiles", changes: [{uri: "file://#{dir}/pages/Page.intl.en.toml", type: 1}])
        published = client.read

        assert_equal(page_uri, published.dig(:params, :uri))
        assert_includes(published.dig(:params, :diagnostics, 0, :message), "Page.intl.en.toml")
      end
    end
  end

  def test_watched_dependency_deletions_refresh_the_importing_document
    Dir.mktmpdir do |dir|
      FileUtils.cp_r("#{Klenod::LSP::TestSupport::FIXTURE_SOURCE_DIR}/.", dir)
      page_uri = "file://#{dir}/pages/Page.haml"

      with_server(source_dir: dir) do |client|
        client.notify("textDocument/didOpen", textDocument: {uri: page_uri, languageId: "haml", version: 1, text: @page_source})
        client.read

        File.delete("#{dir}/pages/layout.rb")
        client.notify("workspace/didChangeWatchedFiles", changes: [{uri: "file://#{dir}/pages/layout.rb", type: 3}])

        assert_includes(client.read.dig(:params, :diagnostics, 0, :message), "Could not resolve \"./layout\"")
      end
    end
  end

  def test_watched_changes_to_unrelated_files_do_not_republish
    with_server do |client|
      client.notify("textDocument/didOpen", textDocument: {uri: @page_uri, languageId: "haml", version: 1, text: @page_source})
      client.read
      client.notify("workspace/didChangeWatchedFiles", changes: [{uri: fixture_uri("pages/LazyPage.haml"), type: 2}, {uri: fixture_uri("entry.rb"), type: 2}])

      response = client.request("shutdown")

      assert(response.key?(:id))
    end
  end

  def test_watched_changes_to_dependencies_republish_the_importer
    with_server do |client|
      client.notify("textDocument/didOpen", textDocument: {uri: @page_uri, languageId: "haml", version: 1, text: @page_source})
      client.read
      client.notify("workspace/didChangeWatchedFiles", changes: [{uri: fixture_uri("components/Details.haml"), type: 2}])
      published = client.read

      assert_equal("textDocument/publishDiagnostics", published[:method])
      assert_equal(@page_uri, published.dig(:params, :uri))
    end
  end

  def test_watched_file_changes_skip_the_changed_document_itself_and_unsupported_clients
    with_server do |client|
      client.request("initialize", capabilities: {})
      client.notify("initialized")
      client.notify("textDocument/didOpen", textDocument: {uri: @page_uri, languageId: "haml", version: 1, text: @page_source})
      client.read
      client.notify("workspace/didChangeWatchedFiles", changes: [{uri: @page_uri, type: 2}])

      response = client.request("shutdown")

      assert(response.key?(:id))
    end
  end

  def test_initialized_indexes_the_workspace_with_progress
    with_server do |client|
      client.request("initialize", capabilities: {window: {workDoneProgress: true}})
      client.notify("initialized")

      create = client.read
      assert_equal("window/workDoneProgress/create", create[:method])
      client.respond(create[:id])

      kinds = []
      loop do
        message = client.read
        assert_equal("$/progress", message[:method])
        kinds << message.dig(:params, :value, :kind)
        break if kinds.last == "end"
      end

      assert_equal("begin", kinds.first)
      assert_includes(kinds, "report")
    end
  end

  def test_references_answer_from_the_index
    with_server do |client|
      client.request("initialize", capabilities: {window: {workDoneProgress: true}})
      client.notify("initialized")
      client.respond(client.read[:id])
      loop { break if client.read.dig(:params, :value, :kind) == "end" }
      client.notify("textDocument/didOpen", textDocument: {uri: @page_uri, languageId: "haml", version: 1, text: @page_source})
      client.read

      result = client.request("textDocument/references", textDocument: {uri: @page_uri}, position: {line: 5, character: 4}, context: {includeDeclaration: false}).fetch(:result)

      assert_equal([fixture_uri("entry.rb"), @page_uri, @page_uri], result.map { |location| location[:uri] })
    end
  end

  def test_documents_outside_the_source_dir_are_ignored
    with_server do |client|
      client.notify("textDocument/didOpen", textDocument: {uri: "file:///elsewhere/Page.haml", languageId: "haml", version: 1, text: "%h1"})
      result = client.request("textDocument/definition", textDocument: {uri: "file:///elsewhere/Page.haml"}, position: {line: 0, character: 1})

      assert_nil(result[:result])
    end
  end

  def test_unknown_requests_are_rejected_and_unknown_notifications_ignored
    with_server do |client|
      client.notify("workspace/somethingNew", {})
      error = client.request("textDocument/rename", {}).fetch(:error)

      assert_equal(-32601, error[:code])
      assert_includes(error[:message], "textDocument/rename")
    end
  end

  def test_handler_failures_answer_with_an_internal_error
    with_server do |client|
      client.notify("textDocument/didOpen", textDocument: {uri: @page_uri, languageId: "haml", version: 1, text: @page_source})
      client.read
      error = client.request("textDocument/definition", textDocument: {uri: @page_uri}, position: {line: "nope", character: 0}).fetch(:error)

      assert_equal(-32603, error[:code])
    end

    assert_includes(@stderr.string, "TypeError")
  end

  def test_stray_output_goes_to_stderr_while_serving
    previous_stderr = $stderr
    $stderr = @stderr

    with_server do |client|
      client.request("initialize", capabilities: {})
      $stdout.puts "not protocol"
      result = client.request("shutdown").fetch(:result)

      assert_nil(result)
    end

    assert_includes(@stderr.string, "not protocol")
  ensure
    $stderr = previous_stderr
  end

  def test_exit_status_depends_on_shutdown
    with_server do |client|
      assert_nil(client.request("shutdown").fetch(:result))
      client.notify("exit")

      assert_equal(0, client.exit_status)
    end

    with_server do |client|
      client.notify("exit")

      assert_equal(1, client.exit_status)
    end
  end

  private

  def with_server(source_dir: Klenod::LSP::TestSupport::FIXTURE_SOURCE_DIR)
    client_to_server_reader, client_to_server_writer = IO.pipe
    server_to_client_reader, server_to_client_writer = IO.pipe
    server = Klenod::LSP::Server.new(context: fixture_context(source_dir:), input: client_to_server_reader, output: server_to_client_writer, logger: Logger.new(@stderr))
    status = Thread.new { server.start }
    client = Client.new(client_to_server_writer, server_to_client_reader, status)

    yield client
  ensure
    client_to_server_writer.close unless client_to_server_writer.closed?
    status&.join(5)
    [client_to_server_reader, server_to_client_reader, server_to_client_writer].each { |io| io.close unless io.closed? }
  end
end
