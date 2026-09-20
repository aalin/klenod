# frozen_string_literal: true
KlenodImport = method(:__klenod_import__)
HamlHelper =
  Klenod::Build::Plugins::HamlPlugin::FixturesTest::FakeFramework::HamlHelper
class OutputCasePattern < TestFramework::ComponentBase
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
    def initialize(result:)
      # SourceMapMark:3
      @result = result
      # SourceMapMark:4
    end
    # SourceMapMark:5
  end
  public def render
    case @result
    in { status: :received, message: } if message
      # SourceMapMark:8
      TestFramework::H[
        :p,
        (message),
        **HamlHelper.merge_props(
          self.class,
          {
            role:
              begin
                # SourceMapMark:8
                "status"
              end
          }
        )
      ]
    in { status: :invalid, errors: [first, *] }
      # SourceMapMark:10
      TestFramework::H[
        :p,
        (first),
        **HamlHelper.merge_props(
          self.class,
          {
            role:
              begin
                # SourceMapMark:10
                "alert"
              end
          }
        )
      ]
    else
      # SourceMapMark:12
      TestFramework::H[
        :p,
        "Unknown request",
        **HamlHelper.merge_props(self.class, {})
      ]
    end
  end
end
Default = OutputCasePattern
ClassNames = Default::ClassNames
Translations = Default::Translations
