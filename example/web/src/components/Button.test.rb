# frozen_string_literal: true

Button = import("./Button.haml")

def test_renders_button_children
  screen = render(Button, "Save", type: "submit")
  button = screen.get_by_role(:button, name: "Save")

  assert_equal("submit", button["type"])
  assert_equal("primary", button["class"])
  refute_includes(screen.html, "components/Button")
end
