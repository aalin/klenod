# frozen_string_literal: true
KlenodImport = method(:__klenod_import__)
HamlHelper =
  Klenod::Build::Plugins::HamlPlugin::FixturesTest::FakeFramework::HamlHelper
class InlineCssFilter < TestFramework::ComponentBase
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
  public def render
    # SourceMapMark:6
    TestFramework::H[
      :h1,
      "Hello",
      **{
        class:
          begin
            # SourceMapMark:6
            HamlHelper.class_names(Styles[:title] || "title")
          end
      }
    ]
  end
end
Default = InlineCssFilter
Styles = {}.freeze
Default.const_set(:Styles, Styles)
Translations = Default::Translations
