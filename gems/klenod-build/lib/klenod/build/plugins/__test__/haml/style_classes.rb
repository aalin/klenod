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
  public def render
    # SourceMapMark:1
    TestFramework::H[
      :figure,
      begin
        # SourceMapMark:2
        TestFramework::H[
          :img,
          **{
            src:
              begin
                # SourceMapMark:2
                "/assets/fish.png"
              end
          },
          **begin
            # SourceMapMark:2
            HamlHelper.merge_props(
              self.class,
              { class: :__img },
              { class: :image }
            )
          end
        ]
      end,
      begin
        # SourceMapMark:3
        TestFramework::H[
          :figcaption,
          "Fresh smoke",
          **begin
            # SourceMapMark:3
            HamlHelper.merge_props(self.class, { class: :__figcaption })
          end
        ]
      end,
      **begin
        # SourceMapMark:1
        HamlHelper.merge_props(
          self.class,
          { class: :__figure },
          { class: :card }
        )
      end
    ]
  end
end
Default = StyleClasses
Styles = {
  __figure: "figure_hash",
  __img: "img_hash",
  card: "card_hash",
  image: "image_hash"
}.freeze
Default.const_set(:Styles, Styles)
Translations = Default::Translations
