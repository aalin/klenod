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
  begin
    # SourceMapMark:2:RGV0YWlscyA9IGltcG9ydCgiY29tcG9uZW50cy9EZXRhaWxzIik=
    Details = import("components/Details")
    # SourceMapMark:3:
  end
  public def render
    # SourceMapMark:4:RGV0YWlscw==
    TestFramework::H[
      Details,
      begin
        # SourceMapMark:5:TG9yZW0gaXBzdW0=
        TestFramework::H[:p, "Lorem ipsum"]
      end,
      **{
        summary:
          begin
            # SourceMapMark:4:RGV0YWlscw==
            "More information"
          end
      }
    ]
  end
end
Default = ComponentImport
Styles = {}.freeze
Default.const_set(:Styles, Styles)
Translations = Default::Translations
