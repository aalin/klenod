# frozen_string_literal: true
KlenodImport = method(:__klenod_import__)
HamlHelper =
  Klenod::Build::Plugins::HamlPlugin::FixturesTest::FakeFramework::HamlHelper
class OutputConditional < TestFramework::ComponentBase
  def self.module_path
    __FILE__
  end
  Self = self
  Translations = {}.freeze
  def self.__klenod_import__(dependency_id)
    KlenodImport.call(dependency_id)
  end
  def __klenod_import__(dependency_id)
    self.class.__klenod_import__(dependency_id)
  end
  ClassNames = __klenod_import__("virtual:klenod/class_names").new({}.freeze)
  begin
    # SourceMapMark:2
    def initialize(show:)
      # SourceMapMark:3
      @show = show
      # SourceMapMark:4
    end
    # SourceMapMark:5
  end
  public def render
    # SourceMapMark:6
    TestFramework::H[
      :section,
      if @show
        # SourceMapMark:8
        TestFramework::H[
          :p,
          "Visible",
          **HamlHelper.merge_props(self.class, {})
        ]
      else
        # SourceMapMark:10
        TestFramework::H[:p, "Empty", **HamlHelper.merge_props(self.class, {})]
      end,
      **HamlHelper.merge_props(self.class, {})
    ]
  end
end
Default = OutputConditional
ClassNames = Default::ClassNames
Translations = Default::Translations
