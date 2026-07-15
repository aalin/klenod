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
  begin
    # SourceMapMark:2:SXRlbSA9IERhdGEuZGVmaW5lKDpuYW1lKQ==
    Item = Data.define(:name)
    # SourceMapMark:3:

    # SourceMapMark:4:ZGVmIGluaXRpYWxpemU=
    def initialize
      # SourceMapMark:5:QGl0ZW1zID0gW0l0ZW0ubmV3KCJBIiksIEl0ZW0ubmV3KCJCIild
      @items = [Item.new("A"), Item.new("B")]
      # SourceMapMark:6:QHNlZW4gPSBbXQ==
      @seen = []
      # SourceMapMark:7:ZW5k
    end
    # SourceMapMark:8:
  end
  public def render
    # SourceMapMark:9:dWw=
    TestFramework::H[
      :ul,
      begin
        # SourceMapMark:10:IEBpdGVtcy5lYWNoIGRvIHxpdGVtfA==
        begin
          @items.each do |item|
            [
              begin
                # SourceMapMark:11:IEBzZWVuIDw8IGl0ZW0ubmFtZQ==
                begin
                  @seen << item.name
                  nil
                end
              end,
              begin
                # SourceMapMark:12:aXRlbS5uYW1l
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
Styles = {}.freeze
Default.const_set(:Styles, Styles)
Translations = Default::Translations
