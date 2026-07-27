# frozen_string_literal: true
KlenodImport = method(:__klenod_import__)
class StaticSubtreeCache < TestFramework::ComponentBase
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
      :article,
      begin
        # SourceMapMark:2
        TestFramework::H[
          :header,
          begin
            # SourceMapMark:3
            TestFramework::H[:h1, "Static title"]
          end,
          begin
            # SourceMapMark:4
            TestFramework::H[:p, "Static lead"]
          end
        ]
      end,
      begin
        # SourceMapMark:5
        TestFramework::H[
          :section,
          begin
            # SourceMapMark:6
            TestFramework::H[:p, (dynamic_message)]
          end
        ]
      end
    ]
  end
end
Default = StaticSubtreeCache
ClassNames = __klenod_import__("virtual:klenod/class_names").new({}.freeze)
Default.const_set(:ClassNames, ClassNames)
Translations = Default::Translations
