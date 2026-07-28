# frozen_string_literal: true

require_relative "../haml_plugin_test_support"

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
end
