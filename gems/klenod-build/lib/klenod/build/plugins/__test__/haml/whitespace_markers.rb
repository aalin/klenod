# frozen_string_literal: true
KlenodImport = method(:__klenod_import__)
class WhitespaceMarkers < TestFramework::ComponentBase
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
    # SourceMapMark:1
    TestFramework::H[
      :p,
      begin
        # SourceMapMark:2
        "before"
      end,
      " ",
      begin
        # SourceMapMark:3
        TestFramework::H[
          :a,
          "link",
          href:
            begin
              # SourceMapMark:3
              "#"
            end
        ]
      end,
      " ",
      begin
        # SourceMapMark:4
        "after"
      end
    ]
  end
end
Default = WhitespaceMarkers
ClassNames = __klenod_import__("virtual:klenod/class_names").new({}.freeze)
Default.const_set(:ClassNames, ClassNames)
Translations = Default::Translations
