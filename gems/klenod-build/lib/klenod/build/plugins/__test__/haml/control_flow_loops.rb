# frozen_string_literal: true
KlenodImport = method(:__klenod_import__)
HamlHelper =
  Klenod::Build::Plugins::HamlPlugin::FixturesTest::FakeFramework::HamlHelper
class ControlFlowLoops < TestFramework::ComponentBase
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
    def initialize(items:)
      # SourceMapMark:3
      @items = items
      # SourceMapMark:4
      @index = 0
      # SourceMapMark:5
    end
    # SourceMapMark:6
  end
  public def render
    [
      begin
        # SourceMapMark:7
        while @index < @items.length
          [
            begin
              # SourceMapMark:8
              TestFramework::H[
                :p,
                (@items.fetch(@index)),
                **HamlHelper.merge_props(self.class, {})
              ]
            end,
            begin
              # SourceMapMark:9
              begin
                @index += 1
                nil
              end
            end
          ]
        end
      end,
      begin
        # SourceMapMark:11
        HamlHelper.capture do
          until @index.zero?
            HamlHelper.append_capture(
              begin
                # SourceMapMark:12
                begin
                  @index -= 1
                  nil
                end
              end
            )
          end
        end
      end,
      begin
        # SourceMapMark:14
        HamlHelper.capture do
          for item in @items
            HamlHelper.append_capture(
              begin
                # SourceMapMark:15
                TestFramework::H[
                  :p,
                  (item),
                  **HamlHelper.merge_props(self.class, {})
                ]
              end
            )
          end
        end
      end
    ]
  end
end
Default = ControlFlowLoops
ClassNames = Default::ClassNames
Translations = Default::Translations
