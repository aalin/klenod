# frozen_string_literal: true

require "minitest/autorun"

require "klenod/plugin/javascript"
require "klenod/plugin/javascript/parser"

class Klenod::Build::Plugins::JavaScriptPlugin::ParserTest < Minitest::Test
  Parser = Klenod::Build::Plugins::JavaScriptPlugin::Parser

  def test_uses_native_parser_when_compiled
    skip "native parser is not compiled" unless Parser.native?

    assert_predicate Parser, :native?
  end

  def test_native_parser_extracts_static_re_export_and_dynamic_imports
    skip "native parser is not compiled" unless Parser.native?

    imports =
      Parser.parse(
        <<~JS,
          import value from "./value.js";
          export { value } from "./shared.js";
          export * from "./all.js";
          import("./panel.js");
        JS
        filename: "app:/entry.js"
      )

    assert_equal(
      [
        ["./value.js", :javascript_import],
        ["./shared.js", :javascript_export],
        ["./all.js", :javascript_export],
        ["./panel.js", :javascript_dynamic_import]
      ],
      imports.map { [it.specifier, it.kind] }
    )
  end

  def test_native_parser_ignores_import_words_in_comments_and_strings
    skip "native parser is not compiled" unless Parser.native?

    imports =
      Parser.parse(
        <<~JS,
          // import "./comment.js";
          const text = "import './string.js'";
          const template = `import "./template.js"`;
          import "./real.js";
        JS
        filename: "app:/entry.js"
      )

    assert_equal(["./real.js"], imports.map(&:specifier))
  end

  def test_native_parser_accepts_import_attributes
    skip "native parser is not compiled" unless Parser.native?

    imports =
      Parser.parse(
        'import data from "./data.json" with { type: "json" };',
        filename: "app:/entry.js"
      )

    assert_equal(["./data.json"], imports.map(&:specifier))
    assert_equal({type: "json"}, imports.fetch(0).attributes)
  end

  def test_fallback_parser_extracts_import_attributes
    imports =
      without_native_parser do
        Parser.parse(
          'import styles from "./styles.css" with { type: "css" };',
          filename: "app:/entry.js"
        )
      end

    assert_equal(["./styles.css"], imports.map(&:specifier))
    assert_equal({type: "css"}, imports.fetch(0).attributes)
  end

  def test_native_parser_reports_syntax_errors
    skip "native parser is not compiled" unless Parser.native?

    error =
      assert_raises(SyntaxError) do
        Parser.parse("import from ;", filename: "app:/broken.js")
      end

    assert_includes(error.message, "app:/broken.js")
  end

  def test_native_transform_strips_typescript_types
    skip "native parser is not compiled" unless Parser.native?

    result =
      Parser.transform(
        <<~TS,
          type Message = string;
          const message: Message = "hello";
          export default message;
        TS
        filename: "app:/message.ts",
        source_kind: :typescript
      )

    refute_includes(result.code, "type Message")
    refute_includes(result.code, ": Message")
    assert_includes(result.code, "const message = \"hello\"")
  end

  def test_native_transform_lowers_jsx
    skip "native parser is not compiled" unless Parser.native?

    result =
      Parser.transform(
        <<~JS,
          export default class Panel extends HTMLElement {
            connectedCallback() {
              this.append(<section hidden>Ready</section>);
            }
          }
        JS
        filename: "app:/panel.jsx",
        source_kind: :javascript_jsx
      )

    assert_includes(result.code, "__klenod_jsx.h(\"section\", {")
    assert_includes(result.code, "hidden: true")
    refute_includes(result.code, "<section")
  end

  def test_native_transform_strips_typescript_and_lowers_tsx_fragments
    skip "native parser is not compiled" unless Parser.native?

    result =
      Parser.transform(
        <<~TS,
          export default class Panel extends HTMLElement {
            connectedCallback(): void {
              this.append(<><span>Ready</span></>);
            }
          }
        TS
        filename: "app:/panel.tsx",
        source_kind: :typescript_jsx
      )

    assert_includes(result.code, "__klenod_jsx.h(__klenod_jsx.Fragment, null")
    assert_includes(result.code, "__klenod_jsx.h(\"span\", null")
    refute_includes(result.code, ": void")
    refute_includes(result.code, "<span")
  end

  private

  def without_native_parser
    previous =
      if Parser.instance_variable_defined?(:@native_parser)
        Parser.instance_variable_get(:@native_parser)
      else
        :__undefined
      end
    Parser.instance_variable_set(:@native_parser, nil)
    yield
  ensure
    if previous == :__undefined
      Parser.remove_instance_variable(:@native_parser) if Parser.instance_variable_defined?(:@native_parser)
    else
      Parser.instance_variable_set(:@native_parser, previous)
    end
  end
end
