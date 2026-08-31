# frozen_string_literal: true
KlenodImport = method(:__klenod_import__)
class ComponentImport < TestFramework::ComponentBase
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
    Details = import("components/Details")
    # SourceMapMark:3
  end
  public def render
    # SourceMapMark:4
    TestFramework::H[
      Details,
      summary:
        begin
          # SourceMapMark:4
          "More information"
        end
    ] do
      [
        begin
          # SourceMapMark:5
          TestFramework::H[:p, "Lorem ipsum"]
        end
      ]
    end
  end
end
Default = ComponentImport
ClassNames = Default::ClassNames
Translations = Default::Translations
