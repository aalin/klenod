# frozen_string_literal: true
KlenodImport = method(:__klenod_import__)
HamlHelper =
  Klenod::Build::Plugins::HamlPlugin::FixturesTest::FakeFramework::HamlHelper
class OutputCaseWhenExpression < TestFramework::ComponentBase
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
    case @result
    when [:legacy, { code: 1 }]
      # SourceMapMark:3
      TestFramework::H[
        :p,
        "Legacy request",
        **HamlHelper.merge_props(self.class, {})
      ]
    when request_type(1, 2)
      # SourceMapMark:5
      TestFramework::H[
        :p,
        "Typed request",
        **HamlHelper.merge_props(self.class, {})
      ]
    else
      # SourceMapMark:7
      TestFramework::H[
        :p,
        "Unknown request",
        **HamlHelper.merge_props(self.class, {})
      ]
    end
  end
end
Default = OutputCaseWhenExpression
ClassNames = Default::ClassNames
Translations = Default::Translations
