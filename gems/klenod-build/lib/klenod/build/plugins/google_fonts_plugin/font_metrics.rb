# frozen_string_literal: true

require "json"

module Klenod
  module Build
    module Plugins
      module GoogleFontsPlugin
        FontMetric = Data.define(
          :family_name,
          :category,
          :ascent,
          :descent,
          :line_gap,
          :units_per_em,
          :x_width_avg
        )

        FallbackFont = Data.define(
          :family,
          :local_family,
          :size_adjust,
          :ascent_override,
          :descent_override,
          :line_gap_override
        )

        class FontMetrics
          DATA_PATH = File.expand_path("font_metrics.json", __dir__)

          def initialize(path: DATA_PATH)
            @path = path
          end

          def [](family)
            values = collection[family]
            return unless values

            FontMetric.new(
              values.fetch("familyName"),
              values.fetch("category"),
              values.fetch("ascent"),
              values.fetch("descent"),
              values.fetch("lineGap"),
              values.fetch("unitsPerEm"),
              values.fetch("xWidthAvg")
            )
          end

          private

          def collection
            @collection ||= JSON.parse(File.binread(@path))
          end
        end

        class FallbackCalculator
          SERIF_FALLBACK = "Times New Roman"
          MONO_FALLBACK = "Courier New"
          SANS_SERIF_FALLBACK = "Arial"

          def initialize(metrics)
            @metrics = metrics
          end

          def call(family)
            font = metrics[family]
            return unless font

            local_family =
              case font.category
              when "serif" then SERIF_FALLBACK
              when "monospace" then MONO_FALLBACK
              else SANS_SERIF_FALLBACK
              end
            fallback = metrics[local_family]
            return unless fallback

            font_average_width = font.x_width_avg.fdiv(font.units_per_em)
            fallback_average_width = fallback.x_width_avg.fdiv(fallback.units_per_em)
            size_adjust = (font_average_width.zero? || fallback_average_width.zero?) ? 1 : font_average_width / fallback_average_width
            adjusted_em_square = font.units_per_em * size_adjust

            FallbackFont.new(
              "#{family} Fallback",
              local_family,
              percentage(size_adjust),
              percentage(font.ascent.fdiv(adjusted_em_square)),
              percentage(font.descent.fdiv(adjusted_em_square)),
              percentage(font.line_gap.fdiv(adjusted_em_square))
            )
          end

          private

          attr_reader :metrics

          def percentage(value)
            format("%.2f%%", value.abs * 100)
          end
        end
      end
    end
  end
end
