# frozen_string_literal: true
KlenodImport = method(:__klenod_import__)
HamlHelper =
  Klenod::Build::Plugins::HamlPlugin::FixturesTest::FakeFramework::HamlHelper
class Spacing3 < TestFramework::ComponentBase
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
        ("Blabla #{asd}")
      end,
      " ",
      begin
        # SourceMapMark:3
        TestFramework::H[
          :a,
          "hopp",
          **HamlHelper.merge_props(
            self.class,
            {
              href:
                begin
                  # SourceMapMark:3
                  "asd"
                end
            }
          )
        ]
      end,
      **HamlHelper.merge_props(self.class, {})
    ]
  end
end
Default = Spacing3
ClassNames = Default::ClassNames
Translations = Default::Translations
