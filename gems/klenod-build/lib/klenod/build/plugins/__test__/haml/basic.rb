# frozen_string_literal: true
KlenodImport = method(:__klenod_import__)
class Basic < TestFramework::ComponentBase
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
      :main,
      begin
        # SourceMapMark:2
        TestFramework::H[:h1, "Hello"]
      end,
      begin
        # SourceMapMark:3
        TestFramework::H[:p, ("From Ruby")]
      end,
      class:
        begin
          # SourceMapMark:1
          ClassNames.class_name(:__main, "shell".upcase)
        end
    ]
  end
end
Default = Basic
ClassNames = Default::ClassNames
Translations = Default::Translations
