# frozen_string_literal: true
KlenodImport = method(:__klenod_import__)
class ObjectReferenceKey < TestFramework::ComponentBase
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
    User = Data.define(:id)
    # SourceMapMark:3
    @user = User.new(15)
    # SourceMapMark:4
  end
  public def render
    # SourceMapMark:5
    TestFramework::H[
      :div,
      "Hello",
      key:
        begin
          # SourceMapMark:5
          [@user, :greeting]
        end
    ]
  end
end
Default = ObjectReferenceKey
ClassNames = Default::ClassNames
Translations = Default::Translations
