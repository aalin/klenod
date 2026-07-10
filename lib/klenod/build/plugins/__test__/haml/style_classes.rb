# frozen_string_literal: true
KlenodImport = method(:__klenod_import__)
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
    # SourceMapMark:1:ZmlndXJl
    TestFramework::H[
      :figure,
      begin
        # SourceMapMark:2:aW1n
        TestFramework::H[
          :img,
          **{
            src:
              begin
                # SourceMapMark:2:aW1n
                "/assets/fish.png"
              end,
            class:
              begin
                # SourceMapMark:2:aW1n
                Klenod::Runtime.class_names(
                  Styles[:__img],
                  Styles[:image] || "image"
                )
              end
          }
        ]
      end,
      begin
        # SourceMapMark:3:RnJlc2ggc21va2U=
        TestFramework::H[
          :figcaption,
          "Fresh smoke",
          **{
            class:
              begin
                # SourceMapMark:3:RnJlc2ggc21va2U=
                Klenod::Runtime.class_names(Styles[:__figcaption])
              end
          }
        ]
      end,
      **{
        class:
          begin
            # SourceMapMark:1:ZmlndXJl
            Klenod::Runtime.class_names(
              Styles[:__figure],
              Styles[:card] || "card"
            )
          end
      }
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
