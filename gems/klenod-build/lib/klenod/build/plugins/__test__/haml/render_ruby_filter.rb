# frozen_string_literal: true
KlenodImport = method(:__klenod_import__)
class RenderRubyFilter < TestFramework::ComponentBase
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
    def initialize(children: nil)
      # SourceMapMark:3
    end
    # SourceMapMark:4
  end
  public def render
    [
      begin
        # SourceMapMark:5
        TestFramework::H[:p, "Before"]
      end,
      begin
        # SourceMapMark:7
        begin
          # SourceMapMark:8
          current_path = request.path
          # SourceMapMark:9
          nil
        end
      end,
      begin
        # SourceMapMark:10
        TestFramework::H[:p, (current_path)]
      end
    ]
  end
end
Default = RenderRubyFilter
Styles = {}.freeze
Default.const_set(:Styles, Styles)
Translations = Default::Translations
