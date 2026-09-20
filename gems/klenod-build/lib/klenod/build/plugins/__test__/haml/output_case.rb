# frozen_string_literal: true
KlenodImport = method(:__klenod_import__)
HamlHelper =
  Klenod::Build::Plugins::HamlPlugin::FixturesTest::FakeFramework::HamlHelper
class OutputCase < TestFramework::ComponentBase
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
    def initialize(request_status:)
      # SourceMapMark:3
      @request_status = request_status
      # SourceMapMark:4
    end
    # SourceMapMark:5
  end
  public def render
    case @request_status
    when "received"
      # SourceMapMark:8
      TestFramework::H[
        :p,
        begin
          # SourceMapMark:9
          "Thanks — we received your request."
        end,
        **HamlHelper.merge_props(
          self.class,
          {
            role:
              begin
                # SourceMapMark:8
                "status"
              end
          }
        )
      ]
    when "invalid"
      # SourceMapMark:11
      TestFramework::H[
        :p,
        begin
          # SourceMapMark:12
          "Enter a valid email address and try again."
        end,
        **HamlHelper.merge_props(
          self.class,
          {
            role:
              begin
                # SourceMapMark:11
                "alert"
              end
          }
        )
      ]
    end
  end
end
Default = OutputCase
ClassNames = Default::ClassNames
Translations = Default::Translations
