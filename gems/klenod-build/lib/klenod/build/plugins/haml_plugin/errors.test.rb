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

  def test_an_unclosed_method_in_a_ruby_filter_fails_during_transformation
    source = <<~HAML
      :ruby
        def initialize
          @count = $initial_count

      %p Count: #{@count}
    HAML

    with_haml_context({"pages/page.haml" => source}) do |_dir, context|
      error = assert_raises(Klenod::Build::Plugins::HamlPlugin::ParseError) { context.collect("pages/page.haml") }

      assert_equal("Haml parse error", error.kind)
      assert_equal(4, error.line)
      assert_includes(error.detail, "Could not parse Ruby filter")
      assert_includes(error.message, "Unmatched keyword, missing `end'")
      refute_includes(error.message, "Generated Ruby")
    end
  end

  def test_an_invalid_render_ruby_filter_fails_during_transformation
    source = <<~HAML
      :ruby
        VALUE = true
      :ruby
        things = {
          foo: "Foo",
          bar: "Bar"
          baz: "Baz"
        }
      %pre= JSON.pretty_generate(things)
    HAML

    with_haml_context({"pages/page.haml" => source}) do |_dir, context|
      error = assert_raises(Klenod::Build::Plugins::HamlPlugin::ParseError) { context.collect("pages/page.haml") }

      assert_equal("Haml parse error", error.kind)
      assert_equal(7, error.line)
      assert_includes(error.detail, "Could not parse Ruby filter")
    end
  end

  def test_an_invalid_silent_script_reports_its_haml_line
    with_haml_context({"pages/page.haml" => "%p Before\n- raise \"foo'\n%p After\n"}) do |_dir, context|
      error = assert_raises(Klenod::Build::Plugins::HamlPlugin::ParseError) { context.collect("pages/page.haml") }

      assert_equal("Haml parse error", error.kind)
      assert_equal(2, error.line)
      assert_includes(error.detail, "Could not parse Haml silent script")
      assert_includes(error.message, "pages/page.haml:2: Haml parse error")
      refute_includes(error.message, "Generated Ruby syntax error")
    end
  end

  def test_an_invalid_output_script_reports_its_haml_line
    with_haml_context({"pages/page.haml" => "%p Before\n= raise \"foo'\n%p After\n"}) do |_dir, context|
      error = assert_raises(Klenod::Build::Plugins::HamlPlugin::ParseError) { context.collect("pages/page.haml") }

      assert_equal(2, error.line)
      assert_includes(error.detail, "Could not parse Haml output script")
      refute_includes(error.message, "Generated Ruby syntax error")
    end
  end

  def test_an_invalid_silent_branch_reports_its_haml_line
    source = <<~HAML
      - if ready )
        %p Ready
    HAML

    with_haml_context({"pages/page.haml" => source}) do |_dir, context|
      error = assert_raises(Klenod::Build::Plugins::HamlPlugin::ParseError) { context.collect("pages/page.haml") }

      assert_equal(1, error.line)
      assert_includes(error.detail, "Could not parse Haml silent branches")
      refute_includes(error.message, "Generated Ruby syntax error")
    end
  end
end
