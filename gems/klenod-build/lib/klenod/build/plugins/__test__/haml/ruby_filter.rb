# frozen_string_literal: true
KlenodImport = method(:__klenod_import__)
class RubyFilter < TestFramework::ComponentBase
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
    # SourceMapMark:2:ZGVmIGhhbmRsZV9jbGljaw==
    def handle_click
      # SourceMapMark:3:OmNsaWNrZWQ=
      :clicked
      # SourceMapMark:4:ZW5k
    end
    # SourceMapMark:5:
  end
  public def render
    # SourceMapMark:6:Q2xpY2sgbWU=
    TestFramework::H[
      :button,
      "Click me",
      **{
        onclick:
          begin
            # SourceMapMark:6:Q2xpY2sgbWU=
            handle_click
          end
      }
    ]
  end
end
Default = RubyFilter
Styles = {}.freeze
Default.const_set(:Styles, Styles)
Translations = Default::Translations
