# frozen_string_literal: true

require_relative "../haml_test_support"

class Klenod::Build::Plugins::HamlPlugin::HelperSourceTest < Klenod::Build::Plugins::HamlPlugin::TestSupport
  def test_haml_helper_needed_for_styleable_templates
    plugin = Klenod::Build::Plugins::HamlPlugin.new

    assert(plugin.send(:haml_helper_needed?, "%p Hello\n", styleable: true))
  end

  def test_haml_helper_needed_for_static_class_syntax
    plugin = Klenod::Build::Plugins::HamlPlugin.new

    assert(plugin.send(:haml_helper_needed?, "%p.notice Hello\n", styleable: false))
  end

  def test_haml_helper_needed_for_slot_syntax
    plugin = Klenod::Build::Plugins::HamlPlugin.new

    assert(plugin.send(:haml_helper_needed?, "%slot(name=\"button\")\n", styleable: false))
  end

  def test_haml_helper_not_needed_for_plain_markup
    plugin = Klenod::Build::Plugins::HamlPlugin.new

    refute(plugin.send(:haml_helper_needed?, "%p Hello\n", styleable: false))
  end

  def test_haml_helper_source_defines_default_module
    plugin = Klenod::Build::Plugins::HamlPlugin.new

    assert_includes(plugin.send(:haml_helper_source), "module Default")
    assert_includes(plugin.send(:haml_helper_source), "def self.merge_props")
  end
end
