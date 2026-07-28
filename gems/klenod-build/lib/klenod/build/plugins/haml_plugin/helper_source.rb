# frozen_string_literal: true

module Klenod
  module Build
    module Plugins
      class HamlPlugin < Plugin
        module HelperSource
          private

          def haml_helper_dependency(module_id)
            Dependency
              .create(
                specifier: HAML_HELPER_SPECIFIER,
                importer_id: module_id,
                kind: :haml_helper
              )
              .with(id: "#{module_id}:haml_helper")
          end

          def haml_helper_source
            <<~RUBY
              # frozen_string_literal: true

              module Default
                def self.merge_props(component_class, *sources)
                  result = {}
                  classes = []

                  sources.each do |source|
                    next unless source

                    source.each do |key, value|
                      key = normalize_prop_key(key)
                      if key == :class
                        collect_class_values(classes, value)
                      else
                        result[key] = value
                      end
                    end
                  end

                  class_name = class_name(component_class, classes)
                  result[:class] = class_name if class_name
                  result
                end

                def self.normalize_prop_key(key)
                  return key if key.is_a?(Symbol) && !key.to_s.include?("-")

                  key.to_s.tr("-", "_").to_sym
                end

                def self.collect_class_values(classes, value)
                  case value
                  when nil, false
                    nil
                  when Array
                    value.each { |item| collect_class_values(classes, item) }
                  else
                    classes << value
                  end
                end

                def self.class_name(component_class, classes)
                  return nil if classes.empty?

                  styles = component_class.const_defined?(:ClassNames, false) ? component_class::ClassNames : nil
                  return nil unless styles.respond_to?(:class_name)

                  styles.class_name(*classes)
                end

                def self.render_slot(component, name = nil, fallback = nil)
                  children =
                    if component.respond_to?(:children)
                      name ? component.children[name] : component.children
                    elsif component.respond_to?(:__slots)
                      component.__slots[name&.to_sym]
                    end

                  return children if children && !children.empty?

                  fallback
                end

                def self.freeze_static(value, seen = {})
                  return value if value.nil? || value == true || value == false || value.is_a?(Symbol) || value.is_a?(Numeric)

                  object_id = value.object_id
                  return value if seen[object_id]

                  seen[object_id] = true

                  case value
                  when String
                    nil
                  when Array
                    value.each { |child| freeze_static(child, seen) }
                  when Hash
                    value.each do |key, child|
                      freeze_static(key, seen)
                      freeze_static(child, seen)
                    end
                  else
                    value.deconstruct.each { |child| freeze_static(child, seen) } if value.respond_to?(:deconstruct)
                  end

                  value.freeze
                end
              end
            RUBY
          end

          def haml_helper_needed?(source, styleable:)
            return true if styleable

            source.match?(STATIC_CLASS_SOURCE_PATTERN) || source.match?(/^\s*%slot\b/)
          end
        end
      end
    end
  end
end
