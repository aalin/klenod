# frozen_string_literal: true

require_relative "test_support"

class Klenod::Build::Plugins::HamlPlugin::HelperSourceTest < Klenod::Build::Plugins::HamlPlugin::TestSupport
  def test_haml_helper_source_defines_default_module
    plugin = Klenod::Build::Plugins::HamlPlugin.new

    assert_includes(plugin.send(:haml_helper_source), "module Default")
    assert_includes(plugin.send(:haml_helper_source), "def self.merge_props")
  end

  def test_haml_helper_preserves_explicit_hyphenated_prop_keys
    props =
      FakeFramework::HamlPluginHelper.merge_props(
        FakeFramework::ComponentBase,
        {"data-role" => "admin", :"aria-label" => "Name"}
      )

    assert_equal({"data-role" => "admin", :"aria-label" => "Name"}, props)
  end

  def test_haml_helper_keeps_component_prop_merging_behavior
    component_class = Class.new
    class_names =
      Module.new do
        def self.class_name(*classes)
          classes.join(" ")
        end
      end
    component_class.const_set(:ClassNames, class_names)

    props =
      FakeFramework::HamlPluginHelper.merge_props(
        component_class,
        {"title" => "Original", "class" => "primary"},
        {title: "Override", class: ["active", nil, false]}
      )

    assert_equal({title: "Override", class: "primary active"}, props)
  end
end
