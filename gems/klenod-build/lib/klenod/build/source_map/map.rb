# frozen_string_literal: true

require "json"

require_relative "vlq"

module Klenod
  module Build
    module SourceMap
      Segment = Data.define(:generated_line, :generated_column, :source_index, :original_line, :original_column, :name_index) do
        def with_generated(line, column)
          self.class.new(line, column, source_index, original_line, original_column, name_index)
        end

        def with_original(line:, column:)
          self.class.new(generated_line, generated_column, source_index, line, column, name_index)
        end

        def mapped?
          source_index && original_line && original_column
        end
      end

      class Map
        attr_reader :version, :source_root, :sources, :sources_content, :names, :segments

        def self.parse(json)
          hash = JSON.parse(json)
          new(
            version: hash.fetch("version"),
            source_root: hash["sourceRoot"],
            sources: hash.fetch("sources"),
            sources_content: hash["sourcesContent"],
            names: hash.fetch("names", []),
            segments: decode_mappings(hash.fetch("mappings"))
          )
        end

        def self.decode_mappings(mappings)
          segments = []
          previous_source_index = 0
          previous_original_line = 0
          previous_original_column = 0
          previous_name_index = 0

          mappings.split(";", -1).each_with_index do |line, generated_line|
            previous_generated_column = 0
            next if line.empty?

            line.split(",").each do |encoded_segment|
              values = VLQ.decode(encoded_segment)
              previous_generated_column += values.fetch(0)

              if values.length == 1
                segments << Segment.new(generated_line, previous_generated_column, nil, nil, nil, nil)
                next
              end

              previous_source_index += values.fetch(1)
              previous_original_line += values.fetch(2)
              previous_original_column += values.fetch(3)
              name_index =
                if values.length > 4
                  previous_name_index += values.fetch(4)
                end

              segments << Segment.new(
                generated_line,
                previous_generated_column,
                previous_source_index,
                previous_original_line,
                previous_original_column,
                name_index
              )
            end
          end

          segments
        end

        def initialize(version:, source_root:, sources:, sources_content:, names:, segments:)
          @version = version
          @source_root = source_root
          @sources = sources
          @sources_content = sources_content
          @names = names
          @segments = segments
        end

        def to_json(*)
          JSON.generate(to_h)
        end

        def to_h
          {
            "version" => version,
            "sourceRoot" => source_root,
            "mappings" => encode_mappings,
            "sources" => sources,
            "sourcesContent" => sources_content,
            "names" => names
          }.compact
        end

        def with(sources: @sources, sources_content: @sources_content, segments: @segments)
          self.class.new(
            version: version,
            source_root: source_root,
            sources: sources,
            sources_content: sources_content,
            names: names,
            segments: segments
          )
        end

        def map_original_lines(source_index:)
          with(
            segments: segments.map do |segment|
              if segment.source_index == source_index
                segment.with_original(line: yield(segment.original_line), column: segment.original_column)
              else
                segment
              end
            end
          )
        end

        def encode_mappings
          return "" if segments.empty?

          grouped = segments.group_by(&:generated_line)
          max_line = segments.map(&:generated_line).max
          previous_source_index = 0
          previous_original_line = 0
          previous_original_column = 0
          previous_name_index = 0

          (0..max_line).map do |generated_line|
            previous_generated_column = 0
            (grouped[generated_line] || [])
              .sort_by(&:generated_column)
              .map do |segment|
                values = [segment.generated_column - previous_generated_column]
                previous_generated_column = segment.generated_column

                if segment.mapped?
                  values << segment.source_index - previous_source_index
                  values << segment.original_line - previous_original_line
                  values << segment.original_column - previous_original_column
                  previous_source_index = segment.source_index
                  previous_original_line = segment.original_line
                  previous_original_column = segment.original_column

                  if segment.name_index
                    values << segment.name_index - previous_name_index
                    previous_name_index = segment.name_index
                  end
                end

                VLQ.encode(values)
              end
              .join(",")
          end.join(";")
        end
      end
    end
  end
end
