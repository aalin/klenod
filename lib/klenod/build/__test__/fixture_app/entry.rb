# frozen_string_literal: true

Page = import("pages/page.haml")
Logo = import("images/logo.png")

def self.render(context)
  [
    Page.new(image: Logo).render,
    context.assets_for("pages/page.css").map(&:output_path),
    context.assets_for("components/Card.css").map(&:output_path),
    context.assets_for("images/logo.png").map(&:output_path)
  ]
end
