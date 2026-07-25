# frozen_string_literal: true
KlenodImport = method(:__klenod_import__)
class DynamicAttributes < TestFramework::ComponentBase
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
      :dialog,
      begin
        # SourceMapMark:2
        TestFramework::H[:p, "Hello"]
      end,
      "data-state":
        begin
          # SourceMapMark:1
          "ready"
        end,
      open:
        begin
          # SourceMapMark:1
          true
        end
    ]
  end
end
Default = DynamicAttributes
Styles = {}.freeze
Default.const_set(:Styles, Styles)
Translations = Default::Translations
