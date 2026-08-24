# klenod-plugin-css

CSS asset and CSS Modules plugin for Klenod, powered by
[Lightning CSS](https://lightningcss.dev/).

The plugin scopes selectors and emits content-hashed CSS assets. `@import`,
`url()`, `composes ... from`, and cross-file local variable references become
Klenod graph dependencies, so changes invalidate the modules that depend on
them.

## Options

```ruby
Klenod::Build::Plugins::CssPlugin::Plugin.new(
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
