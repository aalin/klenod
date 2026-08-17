# frozen_string_literal: true

require "minitest/autorun"

require "klenod/plugin/javascript"
require "klenod/plugin/javascript/parser"

class Klenod::Plugin::JavaScript::ParserTest < Minitest::Test
  Parser = Klenod::Plugin::JavaScript::Parser

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

    assert_includes(result.code, "h(\"section\", {")
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

    assert_includes(result.code, "h(Fragment, null")
    assert_includes(result.code, "h(\"span\", null")
    refute_includes(result.code, ": void")
    refute_includes(result.code, "<span")
  end
end
