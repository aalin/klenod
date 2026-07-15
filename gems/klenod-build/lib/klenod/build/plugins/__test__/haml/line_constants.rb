# frozen_string_literal: true
KlenodImport = method(:__klenod_import__)
class LineConstants < TestFramework::ComponentBase
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
    # SourceMapMark:2:ZGVmIGZpbHRlcl9saW5l
    def filter_line
      # SourceMapMark:3:X19MSU5FX18=
      3
      # SourceMapMark:4:ZW5k
    end
    # SourceMapMark:5:
  end
  public def render
    # SourceMapMark:6:bWFpbg==
    TestFramework::H[
      :main,
      begin
        # SourceMapMark:7:IF9fTElORV9f
        (7)
      end,
      begin
        # SourceMapMark:8:IGZpbHRlcl9saW5l
        (filter_line)
      end,
      begin
        # SourceMapMark:9:ICJfX0xJTkVfXyI=
        ("__LINE__")
      end,
      begin
        # SourceMapMark:10:X19MSU5FX18=
        TestFramework::H[:span, (10)]
      end,
      begin
        # SourceMapMark:11:
        TestFramework::H[
          :section,
          **{
            key:
              begin
                # SourceMapMark:11:
                11
              end
          }
        ]
      end,
      **{
        data_line:
          begin
            # SourceMapMark:6:bWFpbg==
            6
          end
      }
    ]
  end
end
Default = LineConstants
Styles = {}.freeze
Default.const_set(:Styles, Styles)
Translations = Default::Translations
