# frozen_string_literal: true

require "minitest/autorun"

require_relative "../../build/module_id"
require_relative "../../build/profiler"
require_relative "ruby_plugin"

class Klenod::Build::Plugins::RubyPlugin::Test < Minitest::Test
  RubyPlugin = Klenod::Build::Plugins::RubyPlugin
  ModuleId = Klenod::Build::ModuleId
  Profiler = Klenod::Build::Profiler
  Context = Data.define(:profiler)

  def test_creates_dependencies_and_rewrites_literal_imports
    result =
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        "Dep = import(\"../dep\")\n",
        nil
      )

    assert_equal(1, result.dependencies.length)
    assert_equal("../dep", result.dependencies.first.specifier)
    assert_includes(result.code, "__klenod_import__(\"pages/page.rb:dependency:0\")")
  end

  def test_rewrites_literal_imports_without_syntax_tree_scan
    profiler = Profiler.new(enabled: true)
    result =
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        "Dep = import(\"../dep\")\n",
        Context.new(profiler)
      )

    assert_equal(1, result.dependencies.length)
    assert_includes(result.code, "__klenod_import__(\"pages/page.rb:dependency:0\")")
    refute_includes(profiler.totals.keys, :ruby_import_parse)
    refute_includes(profiler.totals.keys, :ruby_import_scan)
  end

  def test_rewrites_imports_with_whitespace
    result =
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        "Dep = import  (  \"../dep\"  )\n",
        nil
      )

    assert_equal("../dep", result.dependencies.first.specifier)
    assert_equal("Dep = __klenod_import__(\"pages/page.rb:dependency:0\")\n", result.code)
  end

  def test_does_not_rewrite_import_text_inside_strings
    code = "value = \"import(\\\"../dep\\\")\"\n"
    result =
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        code,
        nil
      )

    assert_empty(result.dependencies)
    assert_equal(code, result.code)
  end

  def test_does_not_rewrite_import_text_inside_comments
    code = "# import(\"../dep\")\nvalue = 1\n"
    result =
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        code,
        nil
      )

    assert_empty(result.dependencies)
    assert_equal(code, result.code)
  end

  def test_does_not_fast_rewrite_receiver_import_calls
    code = "Dep = loader.import(\"../dep\")\n"
    result =
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        code,
        nil
      )

    assert_empty(result.dependencies)
    assert_equal(code, result.code)
  end

  def test_does_not_fast_rewrite_namespace_import_calls
    code = "Dep = Namespace::import(\"../dep\")\n"
    result =
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        code,
        nil
      )

    assert_empty(result.dependencies)
    assert_equal(code, result.code)
  end

  def test_does_not_fast_rewrite_safe_navigation_import_calls
    code = "Dep = loader&.import(\"../dep\")\n"
    result =
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        code,
        nil
      )

    assert_empty(result.dependencies)
    assert_equal(code, result.code)
  end

  def test_detects_command_style_imports
    assert_raises(Klenod::Build::DynamicImportError) do
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        "Dep = import \"../dep\"\n",
        nil
      )
    end
  end

  def test_skips_generated_runtime_import_helpers
    code = "KlenodImport = method(:__klenod_import__)\n"
    result =
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        code,
        nil
      )

    assert_empty(result.dependencies)
    assert_equal(code, result.code)
  end

  def test_creates_lazy_dependencies_and_rewrites_literal_lazy_imports
    result =
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        "Dep = lazy_import(\"../dep\")\n",
        nil
      )

    assert_equal(1, result.dependencies.length)
    assert_equal("../dep", result.dependencies.first.specifier)
    refute(result.dependencies.first.eager)
    assert_includes(result.code, "__klenod_lazy_import__(\"pages/page.rb:dependency:0\")")
  end

  def test_rejects_dynamic_imports
    assert_raises(Klenod::Build::DynamicImportError) do
      RubyPlugin.new.transform(
        ModuleId.new("pages/page.rb", nil),
        "Dep = import(name)\n",
        nil
      )
    end
  end
end
