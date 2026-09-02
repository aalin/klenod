# frozen_string_literal: true

module Example
  class Form < Component
    def initialize(action:, method: "get", children: [], **props)
      @action = action
      @method = method
      @children = children
      @props = props
    end

    def render
      H[
        :form,
        csrf_field,
        *@children,
        **@props.merge(action: H.localize_href(@action), method: @method)
      ]
    end

    def csrf_field
      return nil if %w[get head].include?(@method.to_s.downcase)

      H[:input, type: "hidden", name: "csrf_token", value: Context.current.request.csrf_token]
    end
  end
end
