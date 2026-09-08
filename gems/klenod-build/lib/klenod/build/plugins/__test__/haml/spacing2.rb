# frozen_string_literal: true
KlenodImport = method(:__klenod_import__)
HamlHelper =
  Klenod::Build::Plugins::HamlPlugin::FixturesTest::FakeFramework::HamlHelper
class Spacing2 < TestFramework::ComponentBase
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
  public def render
    # SourceMapMark:1
    TestFramework::H[
      :div,
      begin
        # SourceMapMark:2
        TestFramework::H[
          :p,
          "Hello World",
          **HamlHelper.merge_props(self.class, {})
        ]
      end,
      begin
        # SourceMapMark:3
        TestFramework::H[
          :p,
          begin
            # SourceMapMark:4
            "Hello World"
          end,
          **HamlHelper.merge_props(self.class, {})
        ]
      end,
      begin
        # SourceMapMark:5
        TestFramework::H[
          :p,
          begin
            # SourceMapMark:6
            "Hello World"
          end,
          **HamlHelper.merge_props(self.class, {})
        ]
      end,
      begin
        # SourceMapMark:8
        TestFramework::H[
          :p,
          begin
            # SourceMapMark:10
            "Hello World"
          end,
          **HamlHelper.merge_props(self.class, {})
        ]
      end,
      **HamlHelper.merge_props(self.class, {})
    ]
  end
end
Default = Spacing2
ClassNames = Default::ClassNames
Translations = Default::Translations
