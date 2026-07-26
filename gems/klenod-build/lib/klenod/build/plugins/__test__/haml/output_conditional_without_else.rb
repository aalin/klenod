# frozen_string_literal: true
KlenodImport = method(:__klenod_import__)
class OutputConditionalWithoutElse < TestFramework::ComponentBase
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
  begin
    # SourceMapMark:2
    def initialize(show:)
      # SourceMapMark:3
      @show = show
      # SourceMapMark:4
    end
    # SourceMapMark:5
  end
  public def render
    # SourceMapMark:6
    TestFramework::H[
      :section,
      if @show
        # SourceMapMark:8
        TestFramework::H[:p, "Visible"]
      end
    ]
  end
end
Default = OutputConditionalWithoutElse
Styles = __klenod_import__("virtual:klenod/styles").new({}.freeze)
Default.const_set(:Styles, Styles)
Translations = Default::Translations
