# frozen_string_literal: true

Button = import("./Button.haml")

def test_renders_button_children
  html = render(Button, "Save", type: "submit")

  assert_includes(html, %(<button type="submit" class="primary">Save</button>))
  refute_includes(html, "components/Button")
end
