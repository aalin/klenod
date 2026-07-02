# frozen_string_literal: true

require "minitest/autorun"

require_relative "../../build/module_id"
require_relative "ruby_plugin"

class Klenod::Build::Plugins::RubyPlugin::Test < Minitest::Test
  RubyPlugin = Klenod::Build::Plugins::RubyPlugin
  ModuleId = Klenod::Build::ModuleId

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
