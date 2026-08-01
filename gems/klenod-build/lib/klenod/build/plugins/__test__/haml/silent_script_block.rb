# frozen_string_literal: true
KlenodImport = method(:__klenod_import__)
class SilentScriptBlock < TestFramework::ComponentBase
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
    Item = Data.define(:name)
    # SourceMapMark:3

    # SourceMapMark:4
    def initialize
      # SourceMapMark:5
      @items = [Item.new("A"), Item.new("B")]
      # SourceMapMark:6
      @seen = []
      # SourceMapMark:7
    end
    # SourceMapMark:8
  end
  public def render
    # SourceMapMark:9
    TestFramework::H[
      :ul,
      begin
        # SourceMapMark:10
        begin
          @items.each do |item|
            [
              begin
                # SourceMapMark:11
                begin
                  @seen << item.name
                  nil
                end
              end,
              begin
                # SourceMapMark:12
                TestFramework::H[:li, (item.name)]
              end
            ]
          end
          nil
        end
      end
    ]
  end
end
Default = SilentScriptBlock
ClassNames = Default::ClassNames
Translations = Default::Translations
