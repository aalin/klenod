# frozen_string_literal: true
KlenodImport = method(:__klenod_import__)
HamlHelper =
  Klenod::Build::Plugins::Haml::Plugin::FixturesTest::FakeFramework::HamlHelper
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
      class:
        begin
          # SourceMapMark:6
          ClassNames.class_name(:__h1, :title)
        end
    ]
  end
end
Default = InlineCssFilter
ClassNames =
  __klenod_import__("virtual:klenod/class_names").new(
    { title: "title_hash" }.freeze
  )
Default.const_set(:ClassNames, ClassNames)
Translations = Default::Translations
