# frozen_string_literal: true
KlenodImport = method(:__klenod_import__)
class SilentConditional < TestFramework::ComponentBase
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
    # SourceMapMark:2:ZGVmIGluaXRpYWxpemUoc2hvdzop
    def initialize(show:)
      # SourceMapMark:3:QHNob3cgPSBzaG93
      @show = show
      # SourceMapMark:4:ZW5k
    end
    # SourceMapMark:5:
  end
  public def render
    # SourceMapMark:6:IGlmIEBzaG93
    if @show
      # SourceMapMark:7:VmlzaWJsZQ==
      TestFramework::H[:p, "Visible"]
    else
      # SourceMapMark:9:RW1wdHk=
      TestFramework::H[:p, "Empty"]
    end
  end
end
Default = SilentConditional
Styles = {}.freeze
Default.const_set(:Styles, Styles)
Translations = Default::Translations
