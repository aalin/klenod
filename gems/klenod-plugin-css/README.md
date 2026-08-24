# klenod-plugin-css

Optional CSS plugin for Klenod build graphs.

## Local CSS variables

CSS custom properties remain global by default. Enable CSS Modules dashed identifiers when configuring the plugin:

```ruby
Klenod::Build::Plugins::CssPlugin::Plugin.new(local_css_variables: true)
```

Declarations and ordinary references are then localized. References may explicitly come from another CSS module or remain global:

```css
.button {
  background: var(--accent-color from "./vars.css");
  color: var(--text-color from global);
}
```

The generated variable name can be customized with `variable_pattern:`. Its default is `[component]-[local]?[hash]` (the leading `--` is added automatically).
