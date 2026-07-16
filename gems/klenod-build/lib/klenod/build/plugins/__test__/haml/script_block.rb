# frozen_string_literal: true
KlenodImport = method(:__klenod_import__)
class ScriptBlock < TestFramework::ComponentBase
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
    Item = Data.define(:name)
    # SourceMapMark:3

    # SourceMapMark:4
    def initialize
      # SourceMapMark:5
      @items = [Item.new("A"), Item.new("B")]
      # SourceMapMark:6
    end
    # SourceMapMark:7
  end
  public def render
    # SourceMapMark:8
    TestFramework::H[
      :ul,
      begin
        # SourceMapMark:9
        @items.map do |item|
          # SourceMapMark:10
          TestFramework::H[:li, (item.name)]
        end
      end
    ]
  end
end
Default = ScriptBlock
Styles = {}.freeze
Default.const_set(:Styles, Styles)
Translations = Default::Translations
