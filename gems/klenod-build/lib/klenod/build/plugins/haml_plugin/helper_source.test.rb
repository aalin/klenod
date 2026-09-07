# frozen_string_literal: true

require_relative "test_support"

class Klenod::Build::Plugins::HamlPlugin::HelperSourceTest < Klenod::Build::Plugins::HamlPlugin::TestSupport
  def test_haml_helper_source_defines_default_module
    plugin = Klenod::Build::Plugins::HamlPlugin.new

    assert_includes(plugin.send(:haml_helper_source), "module Default")
    assert_includes(plugin.send(:haml_helper_source), "def self.merge_props")
  end
end
