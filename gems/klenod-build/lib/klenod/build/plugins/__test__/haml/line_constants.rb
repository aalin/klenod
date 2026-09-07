# frozen_string_literal: true
KlenodImport = method(:__klenod_import__)
HamlHelper =
  Klenod::Build::Plugins::HamlPlugin::FixturesTest::FakeFramework::HamlHelper
class LineConstants < TestFramework::ComponentBase
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
    def filter_line
      # SourceMapMark:3
      3
      # SourceMapMark:4
    end
    # SourceMapMark:5
  end
  public def render
    # SourceMapMark:6
    TestFramework::H[
      :main,
      begin
        # SourceMapMark:7
        (7)
      end,
      begin
        # SourceMapMark:8
        (filter_line)
      end,
      begin
        # SourceMapMark:9
        ("__LINE__")
      end,
      begin
        # SourceMapMark:10
        TestFramework::H[:span, (10), **HamlHelper.merge_props(self.class, {})]
      end,
      begin
        # SourceMapMark:11
        TestFramework::H[
          :section,
          **HamlHelper.merge_props(
            self.class,
            {
              key:
                begin
                  # SourceMapMark:11
                  11
                end
            }
          )
        ]
      end,
      **HamlHelper.merge_props(
        self.class,
        {
          data_line:
            begin
              # SourceMapMark:6
              6
            end
        }
      )
    ]
  end
end
Default = LineConstants
ClassNames = Default::ClassNames
Translations = Default::Translations
