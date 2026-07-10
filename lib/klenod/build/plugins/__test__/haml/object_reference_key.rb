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
  begin
    # SourceMapMark:2:VXNlciA9IERhdGEuZGVmaW5lKDppZCk=
    User = Data.define(:id)
    # SourceMapMark:3:QHVzZXIgPSBVc2VyLm5ldygxNSk=
    @user = User.new(15)
    # SourceMapMark:4:
  end
  public def render
    # SourceMapMark:5:SGVsbG8=
    TestFramework::H[
      :div,
      "Hello",
      **{
        key:
          begin
            # SourceMapMark:5:SGVsbG8=
            [@user, :greeting]
          end
      }
    ]
  end
end
Default = ObjectReferenceKey
Styles = {}.freeze
Default.const_set(:Styles, Styles)
Translations = Default::Translations
