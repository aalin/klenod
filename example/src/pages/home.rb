# frozen_string_literal: true

Shared = import("../shared")
Styles = import("../styles/home.css")

TITLE = "Hello from #{Shared::NAME}"
MESSAGE = Shared::TAGLINE
TITLE_CLASS = Styles.fetch("title")
