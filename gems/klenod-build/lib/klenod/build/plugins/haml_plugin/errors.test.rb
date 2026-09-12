# frozen_string_literal: true

require_relative "test_support"

class Klenod::Build::Plugins::HamlPlugin::ErrorsTest < Klenod::Build::Plugins::HamlPlugin::TestSupport
  def test_haml_transform_result_can_be_built_from_ast
    builder = Klenod::Build::Plugins::HamlPlugin::Transformer::RubyBuilder.new
    ast = builder.program("class Page\nend\n")
    result =
      Klenod::Build::Plugins::HamlPlugin::HamlTransformResult.from_ast(
        ast,
        source: "%h1 Hello\n",
        metadata: {custom: true}
      )

    assert_equal(ast.source, result.code)
    assert_same(ast, result.ast)
    assert_kind_of(Klenod::Runtime::SourceMap::SourceMap, result.source_map)
    assert_equal({custom: true}, result.metadata)
  end

  def test_unparseable_import_in_a_ruby_filter_reports_its_haml_line
    with_haml_context({"pages/page.haml" => ":ruby\n  Details = import(\"/components/Details\")\n  Layout = import(\"./la\n\n%h1 Hello\n"}) do |_dir, context|
      error = assert_raises(Klenod::Build::Plugins::HamlPlugin::ParseError) { context.collect("pages/page.haml") }

      # An unterminated string is reported where the parser gave up: the end
      # of the filter, which includes its trailing blank line.
      assert_includes([3, 4], error.line)
      assert_equal("Haml parse error", error.kind)
      assert_match(/pages\/page\.haml:[34]/, error.message)
      assert_includes(error.message, "unterminated string")
    end
  end
end
