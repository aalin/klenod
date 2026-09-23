## Haml Reference

Klenod Haml is a component language. A `.haml` module becomes a Ruby component class exported as `Default`; rendering it creates values through the configured factory rather than concatenating HTML. The application decides how those values render, serialize props, and escape text.

This reference describes Klenod's Haml behavior. It shares parser syntax with Haml where useful, but it is not an ActionView or HTML-string template language.

## Setup And Module Shape

### Configuration

`HamlPlugin` needs a component base class and a factory. The example application also opts into lazy component children, prop and context variable mappings, and translations:

```ruby
Klenod::Build::Plugins::HamlPlugin.new(
  component_base_class: "Example::Framework::Component",
  factory: "Example::Framework::H",
  component_children: :lazy,
  variables: {
    global: "@__props",
    class: "Example::Framework::Context.current"
  },
  i18n: {
    class: "Example::Framework::Translator",
    constant: "I18n"
  },
  cache_static_subtrees: false
)
```

- `component_base_class` is the superclass of every generated component.
- `factory` receives element tags or component classes, props, and children.
- `component_children` is `:eager` by default, passing children as positional factory arguments. `:lazy` passes component children in a block so a component can defer them, establish context, or select slots. A lazy factory should memoize the block when children may be read more than once.
- `variables` maps `$global`, `@@class`, and `@instance` Haml variables onto framework-owned receivers.
- `i18n` creates the configured helper constant when translation companions are available.
- `cache_static_subtrees` is an experimental optimization that reuses frozen, fully static element subtrees.

### Imports And Methods

Imports and methods normally go in the first top-level `:ruby` filter. That filter becomes class-level Ruby; later Ruby filters and scripts execute while a component instance renders.

```haml
:ruby
  Button = import("/components/Button.haml")

  def title_case(value)
    value.split.map(&:capitalize).join(" ")
  end

%article
  %h1= title_case($title)
  %Button Open
```

An imported Haml module is its component class, so an uppercase tag such as `%Button` passes that class to the factory. JavaScript custom-element descriptors can be used the same way.

## Elements, Text, And Props

### Elements And Plain Text

Indentation creates children. Lines that do not start with Haml syntax are plain text. `%` introduces an element, and `.class` or `#id` without a tag name creates a `div`.

```haml
#main
  .notice.success
    %h1 Welcome
    Plain text is a child value.
```

### Props And Attributes

Use `%tag.class#id` shortcuts and brace or parenthesized props. Both forms end up as Ruby keyword props for the factory.

```haml
%a.button.primary(href=link[:href] data-state="ready") Read more
%button{ type: "button", **button_props, disabled: $disabled } Save
```

Brace props are ordinary Ruby hash expressions and are the right form for conditionals, keyword splats, and nested values. Parenthesized props accept literals, bare attributes such as `open`, and ordinary member or index expressions such as `video_id=video.id` and `href=link[:href]`.

Long parenthesized prop lists can span lines. Unlike upstream Haml, Klenod also accepts a list whose first prop starts on the line after the opening parenthesis:

```haml
%a(
  href="/docs"
  target="_blank"
) Docs
```

Klenod normalizes every prop name to Ruby-style underscores before calling the factory. `data-foo` and `data_foo` both become `data_foo`; `on-change-per-page` and `on_change_per_page` both become `on_change_per_page`. Nested Ruby values keep their shape for the framework to serialize:

```haml
%button(data-foo="foo123"){ data: { bar: "bar456" } } Save
```

The example framework writes that as `data-foo="foo123" data-bar="bar456"`. Do not write `$data-foo`: Ruby reads that as subtraction. Class shorthand, explicit class props, and scoped CSS classes are joined by the Haml helper.

### Event Handlers

A bare method name in a parenthesized event prop becomes a symbol instead of being called during rendering:

```haml
%Pagination(on_change_per_page=handle_set_per_page)
```

This supplies `on_change_per_page: :handle_set_per_page`. Brace props remain ordinary Ruby, so use them when the value should be evaluated immediately.

### Keys And Whitespace

Object references are a Klenod key convention, not conventional Haml's generated id/class behavior:

```haml
%li[item, :notification] New message
```

The bracket expression is passed as the element's key-style prop; the rendering framework decides what keys mean.

Children are adjacent by default: indentation and source-line breaks do not add text spaces. Like JSX, write a space explicitly when the rendered content needs one. `<` inserts one space to the left of a tag and `>` inserts one space to its right; `<>` does both. Markers only add a space when a neighboring child exists, so they do not create leading or trailing edge whitespace.

```haml
%p
  Read
  %a(href="#")<> documentation
  today.
```

## Ruby Output And Control Flow

### Rendered And Silent Ruby

`=` adds an expression's value to the rendered children. `-` runs setup code silently when it has no nested Haml, and returns nested Haml when it does. Use silent control-flow forms for conditional and repeated content:

```haml
- if $signed_in
  %p Welcome back, #$name.
- else
  %a(href="/sign-in") Sign in

- $items.each do |item|
  %li= item.name
```

Use childless `-` scripts for setup and side effects; they evaluate to `nil` and add no output:

```haml
- total = $items.sum(&:price)
%p= total
```

### Branches And Loops

Silent control-flow forms support `if`/`unless`, `case` with `when` or pattern-matching `in`, `begin`/`rescue`/`ensure`, and `while`, `until`, and `for` blocks. Their nested Haml is returned; iterator and loop bodies are captured as child collections.

```haml
- case $result
- in { ok: value }
  %p= value
- else
  %p(role="alert") Could not load the result.
```

Ruby expressions use normal Ruby interpolation. With a configured global receiver, short interpolation is rewritten too: `"Hello #$name"` reads the same prop as `$name`.

## Variables, Components, And Slots

### Variable Mappings

Variable mappings turn Haml's convenient variable forms into indexed receiver access. With the example configuration, `$title` is `(@__props)[:title]` and `@@request` is `(Example::Framework::Context.current)[:request]`. `$*` is the complete global receiver, which makes prop forwarding concise:

```haml
%Card{ **$* }
  %p= $summary
```

Mappings also apply to assignment. If a mapped receiver needs assignment notifications, replace mutable values rather than changing them in place. Unconfigured variable kinds retain normal Ruby behavior; special globals such as `$!`, `$1`, and `$LOAD_PATH`, and underscore-prefixed instance variables such as `@__state`, are never remapped.

### Children And Slots

Components receive their nested values as `$children`. In the example's lazy-children mode, that object is memoized and supports default and named slots:

```haml
%PopoverButton{ title: "Choose language" }
  %span.icon(slot="button")
  %span.code(slot="button") EN
  %a(href="/") English
  %a(href="/sv") Svenska
```

The component can use `$children` for the default slot, `$children[:button]` for a named slot, or declarative `%slot` insertion points with optional fallback children:

```haml
%button
  %slot(name="button") Menu

%div(popover)
%slot
```

### Context

Context is application policy, but the example provides `@@name` through fiber-local context. A component can establish context before lazy descendants or slots render:

```haml
= provide_context(theme: $theme) do
  = $children
```

## Filters And Companion Files

### Rendering Filters

Klenod supports three rendering filters:

```haml
:markdown
  ## A Markdown heading

  Markdown uses the configured component map.

:plain
  This text is rendered unchanged.

:css
  .notice { color: rebeccapurple; }
```

- `:markdown` uses `MarkdownPlugin` and `/markdown-components.rb` when that map exists.
- `:plain` yields its text unchanged.
- `:css` creates inline stylesheet dependencies in the module graph.
- `:ruby` is also supported for Ruby declarations or render-time Ruby, as described above. An empty `:ruby` filter is valid.

### CSS And Translation Companions

A Haml module automatically discovers matching companions:

```text
components/Card.haml
components/Card.css
components/Card.intl.en.toml
components/Card.intl.sv.toml
```

`Card.css` is transformed by `CSSPlugin` and exposed as `ClassNames`. Class selectors use normal keys, such as `ClassNames[:featured]`; tag selectors use `__`-prefixed keys, such as `ClassNames[:__article]`. Haml applies matching scoped tag classes and joins explicit classes such as `%article.featured`.

Translation companions come from `IntlPlugin`. When `i18n` is configured, the generated component gets a helper such as `I18n = Example::Framework::Translator.new(self)`. Without `IntlPlugin`, Haml still compiles with an empty translation map. Adding, changing, or removing either companion type invalidates its owning Haml module in development.

Scoped CSS belongs to the module that renders an element. A layout can style its own sidebar links, but cannot reliably style paragraph or list tags rendered inside another module's `$children`; style reusable child content in the module that owns it.

## Errors And Source Locations

### Parse Errors And Runtime Errors

Haml parses and transforms during collection. Parse errors show the original Haml source and context. Generated Ruby contains source-map marks, so runtime exceptions are rewritten to the source Haml line. Inline CSS and companion CSS retain their own source maps as well.

For a shorter introduction to component structure, companions, slots, and scoped selectors, see the [Haml Components guide](/docs/haml-components).
