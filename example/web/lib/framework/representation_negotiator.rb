# frozen_string_literal: true

require "http/accept"

module Example
  class RepresentationNegotiator
    Match = Data.define(:representation, :quality, :specificity, :range_index, :representation_index)

    def initialize(**representations)
      @representations = representations.to_a.freeze
    end

    def preferred(accept, default: nil, require_top_match: false)
      return default if accept.to_s.strip.empty?

      ranges = parse(accept)
      return default unless ranges
      return nil if require_top_match && !top_range_supported?(ranges)

      matches = @representations.filter_map.with_index do |(representation, media_type), index|
        match_for(representation, media_type, ranges, index)
      end
      matches
        .select { |match| match.quality.positive? }
        .max_by { |match| score(match) }
        &.representation
    end

    private

    def parse(accept)
      ranges = HTTP::Accept::MediaTypes.parse(accept)
      return if ranges.any? { !valid_quality?(quality_parameter(it)) }

      ranges
    rescue HTTP::Accept::ParseError
      nil
    end

    def valid_quality?(quality)
      return true unless quality
      return false unless quality.match?(/\A(?:0(?:\.\d{0,3})?|1(?:\.0{0,3})?)\z/)

      (0.0..1.0).cover?(quality.to_f)
    end

    def top_range_supported?(ranges)
      range = ranges.each_with_index.max_by { |candidate, index| [quality(candidate), specificity(candidate), -index] }&.first
      return false unless range && quality(range).positive?

      @representations.any? { |_representation, media_type| matches?(range, media_type) }
    end

    def match_for(representation, media_type, ranges, representation_index)
      candidates = ranges.each_with_index.select { |range, _index| matches?(range, media_type) }
      range, range_index = candidates.max_by { |candidate, index| [specificity(candidate), -index] }
      return unless range

      Match[representation, quality(range), specificity(range), range_index, representation_index]
    end

    def matches?(range, media_type)
      type, subtype = media_type.split("/", 2)
      (range.type == "*" || range.type.casecmp?(type)) &&
        (range.subtype == "*" || range.subtype.casecmp?(subtype))
    end

    def specificity(range)
      return 0 if range.type == "*"
      return 1 if range.subtype == "*"

      2
    end

    def quality(range)
      quality_parameter(range)&.to_f || 1.0
    end

    def quality_parameter(range)
      range.parameters.find { |name, _value| name.casecmp?("q") }&.last
    end

    def score(match)
      [match.quality, match.specificity, -match.range_index, -match.representation_index]
    end

    PAGE = new(html: "text/html", markdown: "text/markdown")
    HTML = new(html: "text/html")
  end
end
