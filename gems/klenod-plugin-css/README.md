# klenod-plugin-css

CSS asset and CSS Modules plugin for
[Klenod](https://github.com/aalin/klenod), powered by
[Lightning CSS](https://lightningcss.dev/).

## Options

```ruby
require "klenod/plugin/css"

Klenod::Build::Plugins::CSSPlugin.new(
  source_maps: :development,
  minify: false,
  class_pattern: "[component].[local]?[hash]",
  tag_pattern: "[component]_[local]?[hash]",
  local_css_variables: false,
  variable_pattern: "[component]-[local]?[hash]"
)
```

- `source_maps:` accepts `false`, `true`, or `:development` (the default).
- `minify:` also minifies in development when `true`; build output is always
  minified.
- `class_pattern:` and `tag_pattern:` control generated selector names.
- `local_css_variables:` enables CSS Modules dashed identifiers.
- `variable_pattern:` controls generated local variable names; the leading
  `--` is added automatically.

## Local CSS variables

CSS custom properties remain global by default. When
`local_css_variables: true`, declarations and ordinary references are scoped.
References can explicitly come from another CSS module or remain global:

```css
.button {
  background: var(--accent-color from "./vars.css");
  color: var(--text-color from global);
}
```
