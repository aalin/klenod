# frozen_string_literal: true
KlenodImport = method(:__klenod_import__)
HamlHelper =
  Klenod::Build::Plugins::HamlPlugin::FixturesTest::FakeFramework::HamlHelper
class OutputBeginRescue < TestFramework::ComponentBase
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
    begin
      # SourceMapMark:2
      TestFramework::H[
        :p,
        "Loading your request.",
        **HamlHelper.merge_props(self.class, {})
      ]
    rescue StandardError => error
      # SourceMapMark:4
      TestFramework::H[
        :p,
        (error.message),
        **HamlHelper.merge_props(
          self.class,
          {
            role:
              begin
                # SourceMapMark:4
                "alert"
              end
          }
        )
      ]
    ensure
      # SourceMapMark:6
      TestFramework::H[
        :p,
        "Request complete.",
        **HamlHelper.merge_props(self.class, {})
      ]
    end
  end
end
Default = OutputBeginRescue
ClassNames = Default::ClassNames
Translations = Default::Translations
