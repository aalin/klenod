# frozen_string_literal: true
KlenodImport = method(:__klenod_import__)
HamlHelper =
  Klenod::Build::Plugins::HamlPlugin::FixturesTest::FakeFramework::HamlHelper
class StyleClasses < TestFramework::ComponentBase
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
  ClassNames =
    __klenod_import__("virtual:klenod/class_names").new(
      {
        __figure: "figure_hash",
        __img: "img_hash",
        card: "card_hash",
        image: "image_hash"
      }.freeze
    )
  public def render
    # SourceMapMark:1
    TestFramework::H[
      :figure,
      begin
        # SourceMapMark:2
        TestFramework::H[
          :img,
          **HamlHelper.merge_props(
            self.class,
            {
              src:
                begin
                  # SourceMapMark:2
                  "/assets/fish.png"
                end,
              class:
                begin
                  # SourceMapMark:2
                  %i[__img image]
                end
            }
          )
        ]
      end,
      begin
        # SourceMapMark:3
        TestFramework::H[
          :figcaption,
          "Fresh smoke",
          **HamlHelper.merge_props(
            self.class,
            {
              class:
                begin
                  # SourceMapMark:3
                  :__figcaption
                end
            }
          )
        ]
      end,
      **HamlHelper.merge_props(
        self.class,
        {
          class:
            begin
              # SourceMapMark:1
              %i[__figure card]
            end
        }
      )
    ]
  end
end
Default = StyleClasses
ClassNames = Default::ClassNames
Translations = Default::Translations
