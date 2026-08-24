# frozen_string_literal: true

require "json"

begin
  require "klenod/plugin/css/native"
rescue LoadError
  nil
end

module Klenod
  module Plugin
    module CSS
      class Error < StandardError; end
      class ParseError < Error; end

      ImportDependency = Data.define(:url, :placeholder, :supports, :media, :loc)
      UrlDependency = Data.define(:url, :placeholder, :loc)
      Export = Data.define(:name, :composes, :referenced?)
      ComposeLocal = Data.define(:name)
      ComposeGlobal = Data.define(:name)
      ComposeDependency = Data.define(:name, :specifier)
      VariableDependency = Data.define(:name, :specifier)

      Loc = Data.define(:file_path, :start, :end) do
        def self.from_ext(data) =
          new(
            file_path: data.fetch("filePath"),
            start: Pos.from_ext(data.fetch("start")),
            end: Pos.from_ext(data.fetch("end"))
          )
      end

      Pos = Data.define(:line, :column) do
        def self.from_ext(data) =
          new(data.fetch("line"), data.fetch("column"))
      end

      TransformResult = Data.define(:classes, :elements, :variables, :serialized_variables, :code, :source_map, :dependencies, :exports, :references) do
        def self.from_ext(data) =
          new(
            classes: data.fetch("classes").transform_keys(&:to_sym),
            elements: data.fetch("elements").transform_keys(&:to_sym),
            variables: data.fetch("variables"),
            serialized_variables: data.fetch("serialized_variables"),
            code: data.fetch("code"),
            source_map: data.fetch("source_map"),
            dependencies: JSON.parse(data.fetch("dependencies")).map { dependency_from_ext(it) },
            exports: JSON.parse(data.fetch("exports")).transform_values { export_from_ext(it) },
            references: JSON.parse(data.fetch("references")).transform_values { reference_from_ext(it) }
          )

        def self.dependency_from_ext(dep)
          case dep.fetch("type")
          when "import"
            ImportDependency[
              url: dep.fetch("url"),
              placeholder: dep.fetch("placeholder"),
              supports: dep.fetch("supports"),
              media: dep.fetch("media"),
              loc: Loc.from_ext(dep.fetch("loc"))
            ]
          when "url"
            UrlDependency[
              url: dep.fetch("url"),
              placeholder: dep.fetch("placeholder"),
              loc: Loc.from_ext(dep.fetch("loc"))
            ]
          end
        end

        def self.export_from_ext(export)
          Export[
            name: export.fetch("name"),
            referenced?: export.fetch("isReferenced"),
            composes: export.fetch("composes").map do |compose|
              case compose.fetch("type")
              when "local"
                ComposeLocal[name: compose.fetch("name").to_sym]
              when "global"
                ComposeGlobal[name: compose.fetch("name")]
              when "dependency"
                ComposeDependency[name: compose.fetch("name").to_sym, specifier: compose.fetch("specifier")]
              end
            end
          ]
        end

        def self.reference_from_ext(reference)
          case reference.fetch("type")
          when "dependency"
            VariableDependency[
              name: reference.fetch("name"),
              specifier: reference.fetch("specifier")
            ]
          end
        end
      end

      module Transformer
        module_function

        def native?
          !native_transformer.nil?
        end

        def transform(
          file,
          code,
          minify: true,
          transform_names: true,
          class_pattern: "[component].[local]?[hash]",
          tag_pattern: "[component]_[local]?[hash]",
          local_css_variables: false,
          variable_pattern: "[component]-[local]?[hash]"
        )
          native = native_transformer || raise(Error, "CSS support requires the klenod-plugin-css native extension. Run `bundle exec rake compile` in gems/klenod-plugin-css.")
          TransformResult.from_ext(
            native.transform_native(
              code,
              file,
              {
                "minify" => minify,
                "transform_names" => transform_names,
                "class_pattern" => class_pattern,
                "tag_pattern" => tag_pattern,
                "local_css_variables" => local_css_variables,
                "variable_pattern" => variable_pattern
              }
            )
          )
        end

        def native_transformer
          @native_transformer =
            if defined?(@native_transformer)
              @native_transformer
            else
              begin
                require "klenod/plugin/css/native"
                Klenod::Plugin::CSS::Native
              rescue LoadError
                nil
              end
            end
        end
      end
    end
  end
end
