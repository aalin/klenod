# frozen_string_literal: true

require "json"
require "stringio"

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

  def with_server
    client_to_server_reader, client_to_server_writer = IO.pipe
    server_to_client_reader, server_to_client_writer = IO.pipe
    server = Klenod::LSP::Server.new(context: fixture_context, input: client_to_server_reader, output: server_to_client_writer, logger: Logger.new(@stderr))
    status = Thread.new { server.start }
    client = Client.new(client_to_server_writer, server_to_client_reader, status)

    yield client
  ensure
    client_to_server_writer.close unless client_to_server_writer.closed?
    status&.join(5)
    [client_to_server_reader, server_to_client_reader, server_to_client_writer].each { |io| io.close unless io.closed? }
  end
end
