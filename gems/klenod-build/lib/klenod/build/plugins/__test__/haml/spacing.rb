# frozen_string_literal: true
KlenodImport = method(:__klenod_import__)
HamlHelper =
  Klenod::Build::Plugins::HamlPlugin::FixturesTest::FakeFramework::HamlHelper
class Spacing < TestFramework::ComponentBase
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
      :p,
      begin
        # SourceMapMark:2
        "There should be no space on the left of this text. But there should be one between this line and the previous line."
      end,
      " ",
      begin
        # SourceMapMark:4
        TestFramework::H[
          :a,
          "And there should be spaces before this link",
          **HamlHelper.merge_props(
            self.class,
            {
              href:
                begin
                  # SourceMapMark:4
                  "/"
                end
            }
          )
        ]
      end,
      begin
        # SourceMapMark:5
        ". Was there?"
      end,
      **HamlHelper.merge_props(self.class, {})
    ]
  end
end
Default = Spacing
ClassNames = Default::ClassNames
Translations = Default::Translations
