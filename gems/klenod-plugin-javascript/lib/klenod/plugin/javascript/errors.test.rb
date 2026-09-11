# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require "klenod/plugin/css"
require "klenod/plugin/javascript"

class Klenod::Build::Plugins::JavaScriptPlugin::ErrorsTest < Minitest::Test
  ParseError = Klenod::Build::Plugins::JavaScriptPlugin::ParseError

  # Raw CSS inside a JSX <style> element: the brace opens a JSX expression
  # container, so the colon is a syntax error.
  BROKEN_TSX = <<~TSX
    export default class Thing extends HTMLElement {
      connectedCallback(): void {
        this.append(
          <div>
            <style>
              #root { color: red; }
            </style>
          </div>
        );
      }
    }
  TSX

  VALID_TSX = <<~TSX
    export default class Thing extends HTMLElement {
      connectedCallback(): void {
        this.append(<span>hello</span>);
      }
    }
  TSX

  BROKEN_LINE = 6

  def test_parse_error_is_a_standard_error
    # A bare SyntaxError is a ScriptError, which escapes every `rescue => e`
    # in the build and kills the watcher thread.
    assert_operator(ParseError, :<, StandardError)
  end

  def test_parse_error_carries_module_id_source_and_location
    error = ParseError.new(syntax_error, source: BROKEN_TSX, module_id: "app:/Thing.tsx")

    assert_equal("app:/Thing.tsx", error.module_id)
    assert_equal(BROKEN_TSX, error.source)
    assert_equal(BROKEN_LINE, error.line)
    assert_operator(error.column, :>, 0)
    assert_instance_of(SyntaxError, error.cause)
  end

  def test_parse_error_message_includes_location_and_source_excerpt
    error = ParseError.new(syntax_error, source: BROKEN_TSX, module_id: "app:/Thing.tsx")

    assert_includes(error.message, "app:/Thing.tsx:#{BROKEN_LINE}: JavaScript parse error")
    assert_includes(error.message, "Expected '</', got ':'")
    assert_includes(error.message, "#root { color: red; }")
  end

  def test_parse_error_backtrace_points_at_the_module
    error = ParseError.new(syntax_error, source: BROKEN_TSX, module_id: "app:/Thing.tsx")

    # The browser dialog highlights source lines by matching backtrace frames
    # against the filename.
    assert_equal("app:/Thing.tsx:#{BROKEN_LINE}:#{error.column}", error.backtrace.fetch(0))
  end

  def test_parse_error_without_a_location_still_carries_the_source
    error = ParseError.new(SyntaxError.new("no location here"), source: BROKEN_TSX, module_id: "app:/Thing.tsx")

    assert_nil(error.line)
    assert_nil(error.column)
    assert_equal(BROKEN_TSX, error.source)
    assert_includes(error.message, "app:/Thing.tsx: JavaScript parse error")
    assert_includes(error.message, "no location here")
  end

  def test_invalidating_a_broken_module_collects_the_error_instead_of_raising
    Dir.mktmpdir do |dir|
      File.write("#{dir}/entry.rb", "Default = import(\"Thing.tsx\")\n")
      File.write("#{dir}/Thing.tsx", VALID_TSX)

      context = context_for(dir)
      context.evaluate("entry")

      File.write("#{dir}/Thing.tsx", BROKEN_TSX)
      result = context.invalidate_paths(["#{dir}/Thing.tsx"])

      refute_empty(result.errors)
      _module_id, error = result.errors.fetch(0)
      assert_instance_of(ParseError, error)
      assert_equal(BROKEN_LINE, error.line)
      assert_equal(BROKEN_TSX, error.source)
    end
  end

  private

  def syntax_error
    Klenod::Build::Plugins::JavaScriptPlugin::Parser.transform(
      BROKEN_TSX,
      filename: "app:/Thing.tsx",
      source_kind: :typescript_jsx
    )
    flunk("Expected a SyntaxError")
  rescue ScriptError => e
    e
  end

  def context_for(dir)
    Klenod::Build::Context.new(
      source_dir: dir,
      mode: :development,
      base: "/assets/",
      plugins: [
        *Klenod::Build::Context.default_plugins,
        Klenod::Build::Plugins::CSSPlugin.new,
        Klenod::Build::Plugins::JavaScriptPlugin.new
      ]
    )
  end
end
