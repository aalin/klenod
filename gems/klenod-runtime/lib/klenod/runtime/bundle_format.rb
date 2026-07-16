# frozen_string_literal: true

require "json"

require_relative "version"
require_relative "source_map"

module Klenod
  module Runtime
    class BundleFormatError < StandardError
    end

    module BundleFormat
      MAGIC = "MODPACK_BUNDLE_V1\n"
      FORMAT_VERSION = 1

      module_function

      def dump(bundle)
        MAGIC + JSON.generate(payload_for(bundle))
      end

      def load(source, source_root: nil)
        load_bytes(read_source(source), source_root: source_root)
      end

      def load_bytes(bytes, source_root: nil)
        raise BundleFormatError, "Invalid Klenod bundle header" unless bytes.start_with?(MAGIC)

        body = bytes.byteslice(MAGIC.bytesize, bytes.bytesize - MAGIC.bytesize)
        payload = JSON.parse(body)
        bundle_from_payload(payload, source_root: source_root)
      rescue JSON::ParserError => error
        raise BundleFormatError, "Invalid Klenod bundle JSON: #{error.message}"
      end

      def payload_for(bundle)
        {
          "format_version" => FORMAT_VERSION,
          "runtime_version" => Runtime::VERSION,
          "source_root" => encode_value(bundle.source_root),
          "entrypoints" => encode_value(bundle.entrypoints),
          "modules" => encode_modules(bundle.modules),
          "assets" => encode_assets(bundle.assets)
        }
      end

      def bundle_from_payload(payload, source_root: nil)
        validate_payload!(payload)

        bundle =
          Bundle.new(
            decode_value(payload.fetch("entrypoints")),
            decode_modules(payload.fetch("modules")),
            decode_assets(payload.fetch("assets")),
            source_root: decode_value(payload["source_root"])
          )
        bundle.source_root = source_root if source_root
        bundle
      end

      def read_source(source)
        source.respond_to?(:read) ? source.read : File.binread(source)
      end

      def validate_payload!(payload)
        raise BundleFormatError, "Malformed Klenod bundle payload" unless payload.is_a?(Hash)

        version = payload["format_version"]
        unless version == FORMAT_VERSION
          raise BundleFormatError, "Unsupported Klenod bundle format version: #{version.inspect}"
        end

        %w[runtime_version source_root entrypoints modules assets].each do |key|
          raise BundleFormatError, "Malformed Klenod bundle payload: missing #{key}" unless payload.key?(key)
        end
      end

      def encode_modules(modules)
        modules.to_h do |id, spec|
          [
            id.to_s,
            {
              "id" => spec.id,
              "source_path" => spec.source_path,
              "source" => spec.source,
              "imports" => encode_imports(spec.imports),
              "source_map" => encode_source_map(spec.source_map),
              "version" => spec.version,
              "constant_name" => spec.constant_name
            }
          ]
        end
      end

      def decode_modules(payload)
        expect_hash!(payload, "modules").to_h do |id, spec_payload|
          spec_payload = expect_hash!(spec_payload, "module #{id}")
          [
            id,
            ModuleSpec.new(
              spec_payload.fetch("id"),
              spec_payload.fetch("source_path"),
              spec_payload.fetch("source"),
              decode_imports(spec_payload.fetch("imports")),
              decode_source_map(spec_payload["source_map"], spec_payload.fetch("source")),
              spec_payload.fetch("version"),
              spec_payload.fetch("constant_name")
            )
          ]
        end
      end

      def encode_imports(imports)
        imports.to_h { |name, import| [name.to_s, encode_import(import)] }
      end

      def decode_imports(payload)
        expect_hash!(payload, "imports").to_h { |name, import| [name, decode_import(import)] }
      end

      def encode_import(import)
        case import
        when ImportSpec
          {
            "type" => "import_spec",
            "target_id" => import.target_id,
            "value" => encode_value(import.value),
            "eager" => import.eager
          }
        else
          {
            "type" => "module_id",
            "target_id" => import.to_s
          }
        end
      end

      def decode_import(payload)
        payload = expect_hash!(payload, "import")
        case payload.fetch("type")
        when "import_spec"
          ImportSpec.new(payload.fetch("target_id"), decode_value(payload["value"]), payload.fetch("eager"))
        when "module_id"
          payload.fetch("target_id")
        else
          raise BundleFormatError, "Unknown import type: #{payload["type"].inspect}"
        end
      end

      def encode_assets(assets)
        assets.to_h do |output_path, asset|
          [
            output_path.to_s,
            {
              "logical_name" => asset.logical_name,
              "content_hash" => asset.content_hash,
              "output_path" => asset.output_path,
              "content_type" => asset.content_type,
              "metadata" => encode_value(asset.metadata)
            }
          ]
        end
      end

      def decode_assets(payload)
        expect_hash!(payload, "assets").to_h do |output_path, asset_payload|
          asset_payload = expect_hash!(asset_payload, "asset #{output_path}")
          [
            output_path,
            AssetSpec.new(
              asset_payload.fetch("logical_name"),
              asset_payload.fetch("content_hash"),
              asset_payload.fetch("output_path"),
              asset_payload.fetch("content_type"),
              decode_value(asset_payload.fetch("metadata"))
            )
          ]
        end
      end

      def encode_source_map(source_map)
        return nil unless source_map

        {
          "input" => source_map.input,
          "marks_by_output_line" =>
            source_map.marks_by_output_line.to_h do |line, mark|
              [line.to_s, {"line" => mark.line, "source" => mark.source}]
            end
        }
      end

      def decode_source_map(payload, output)
        return nil unless payload

        payload = expect_hash!(payload, "source map")
        marks =
          expect_hash!(payload.fetch("marks_by_output_line"), "source map marks").to_h do |line, mark_payload|
            mark_payload = expect_hash!(mark_payload, "source map mark")
            [line.to_i, SourceMap::Mark.new(mark_payload.fetch("line"), mark_payload.fetch("source"))]
          end
        SourceMap::SourceMap.new(payload.fetch("input"), output, marks.freeze)
      end

      def encode_value(value)
        case value
        when nil, true, false, String, Integer, Float
          value
        when Symbol
          {"__klenod_type" => "symbol", "value" => value.to_s}
        when Array
          value.map { |item| encode_value(item) }
        when Hash
          {
            "__klenod_type" => "hash",
            "entries" =>
              value.map do |key, hash_value|
                [encode_value(key), encode_value(hash_value)]
              end
          }
        when DefaultImport
          {"__klenod_type" => "default_import", "name" => value.name.to_s}
        else
          raise BundleFormatError, "Cannot encode bundle value: #{value.class}"
        end
      end

      def decode_value(value)
        case value
        when nil, true, false, String, Integer, Float
          value
        when Array
          value.map { |item| decode_value(item) }
        when Hash
          case value["__klenod_type"]
          when "symbol"
            value.fetch("value").to_sym
          when "hash"
            value.fetch("entries").to_h do |key, hash_value|
              [decode_value(key), decode_value(hash_value)]
            end
          when "default_import"
            DefaultImport.new(value.fetch("name").to_sym)
          else
            value.to_h { |key, hash_value| [key, decode_value(hash_value)] }
          end
        else
          raise BundleFormatError, "Cannot decode bundle value: #{value.class}"
        end
      end

      def expect_hash!(value, label)
        return value if value.is_a?(Hash)

        raise BundleFormatError, "Malformed Klenod bundle payload: #{label} must be an object"
      end
    end
  end
end
