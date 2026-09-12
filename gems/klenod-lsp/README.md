# klenod-lsp

A [Language Server Protocol](https://microsoft.github.io/language-server-protocol/) server for Klenod applications. It transforms open editor documents with the same plugins as a build and reports the result back to the editor.

Current support covers Haml modules and the `import("...")` literals of Ruby modules under the source directory:

- Diagnostics: Haml syntax errors, Ruby syntax errors inside Haml, syntax errors in the generated component Ruby, and unresolved imports with the same "did you mean" suggestions the build prints.
- Go to definition: `import("...")` literals and `%Component` tags jump to the imported file. Component tags are followed through the constant bound in the leading `:ruby` filter, such as `Details = import("/components/Details")`.
- Hover: the same targets show their module id and path. Haml components also list the `$name` props they read when the Haml plugin maps global variables to props.
- Completion: `%` offers the components bound by imports in the file, and the string inside `import("...")` offers directories and files under the source directory, relative to the importing module or to the source root for leading-slash paths.
- Quick fixes: an unresolved import offers the build's own suggestions, such as a corrected casing or a close filename, as code actions that replace the literal.
- Document links: every resolvable `import("...")` literal is a clickable link to its file.
- Find references: importers of a module and the `%Component` tags that render it, from the collected graph. The cursor can be on an import literal, a component tag, the constant a module is bound to, or anywhere else to mean the current document.
- Rename on file move: when the editor renames or moves a file or folder, importers get their literals rewritten and the moved module's own relative imports follow it. Each literal keeps its style and its extension only when it had one.
- Workspace diagnostics: modules the index could not collect get diagnostics even while closed, so a rename or deletion that breaks importers shows up in the problem list, and they clear once the module recovers.
- Document symbols: an outline of a Haml component from its parse tree, with the constants and methods of the leading `:ruby` filter and the tag tree. Ruby modules list their import bindings.
- Workspace symbols: fuzzy search over every indexed module by name or path.
- Code lens: the number of places that import or render a module, on its first line, opening the reference list in clients that know VS Code's `showReferences` command.
- Route lenses and hovers: with the router plugin configured, a page or handler shows the route it serves, a layout shows how many routes it wraps, and a special view shows its kind and path. Hovering the first line of such a file shows the route's params, page and handler files, and layout chain.
- Rename symbol: renaming the constant a module is bound to, from the binding or a `%Name` tag, updates the binding, every tag, and the Ruby uses in that file, leaving plain text and string literals alone.
- Unused imports: a constant bound by an import but never used as a `%Name` tag or in Ruby gets a warning tagged as unnecessary.
- CSS classes in Haml: the `.name` shorthand on tags and `ClassNames[:name]` lookups are checked against the companion stylesheet and inline `:css` filters. Unknown classes get a warning when the component has styles, definition jumps to the selector, hover shows the generated class name, and completion offers the defined classes.

Ruby modules get the diagnostics, navigation, completion, quick fixes, and links for their import literals. Everything else about Ruby is left to a Ruby language server.

Stylesheets get the same treatment for their `@import`, `url()`, and `composes ... from` references, resolved the way the CSS plugin resolves them, including fonts and images.

The server never evaluates application code. Diagnostics for an open document come from transforming its buffer. Cross-file features come from a module graph collected in the background in analysis mode: the configured entrypoints plus every Ruby and Haml file under the source directory, following lazy imports such as router pages. Analysis mode keeps plugins from doing asset work, so no images are hashed or resized, no fonts are downloaded, no JavaScript is compiled, and nothing is written. Open buffers overlay the files on disk, and indexing reports progress when the client supports `window/workDoneProgress`.

The server does not watch files itself. When the client supports dynamic registration it asks the editor to report changes under the source directory and runs them through the build's own invalidation, which keeps the graph current and re-analyzes the open documents a change affects. Clients without dynamic registration need a static watcher configuration.

## Starting the server

Applications configured with `klenod.config.rb` add the gem to their Gemfile and use the `klenod` command. The `klenod` meta gem does not depend on `klenod-lsp`; without it, `klenod lsp` prints what to install.

```ruby
gem "klenod-lsp"
```

```sh
bundle exec klenod lsp
```

Frameworks that build their `Klenod::Build::Config` in Ruby start the same server from their own script. The web example does this in `example/web/bin/lsp`:

```ruby
require "klenod/lsp"

config = Example::WebConfig.build_config(mode: :development)
context = config.context(analysis: true)
exit Klenod::LSP::Server.new(context: context, entrypoints: config.entrypoints).start
```

Build the context with `analysis: true` so plugins skip asset work, and pass the entrypoints so the graph index covers everything reachable from them. Without entrypoints the index still covers every source file.

`Klenod::LSP::Server.new(context:)` speaks JSON-RPC over stdin and stdout. Anything printed to `$stdout` while the server runs is redirected to stderr so plugin output cannot corrupt the protocol stream. `start` returns the process exit status: `0` after the client sent `shutdown`, `1` otherwise.

## Editor configuration

The server handles documents whose file extension is `.haml`, `.rb`, or `.css` and whose path lies inside the configured source directory. Point your editor's LSP client at the start command and the `haml` file type, and optionally the `ruby` and `css` file types for import navigation alongside the language servers you already run for those.

Neovim:

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "haml",
  callback = function()
    vim.lsp.start({
      name = "klenod",
      cmd = { "bin/lsp" }, -- or { "bundle", "exec", "klenod", "lsp" }
      root_dir = vim.fs.root(0, { "klenod.config.rb", "Gemfile" }),
    })
  end,
})
```

Helix (`languages.toml`):

```toml
[language-server.klenod]
command = "bin/lsp"

[[language]]
name = "haml"
language-servers = ["klenod"]
```

Zed (`.zed/settings.json`) can run it through a generic language server extension, and VS Code needs a small client extension or a generic LSP client extension that maps the `haml` language to the command.

## Limitations

- Positions are counted in characters. Clients that offer the `utf-32` position encoding get exact positions; with the `utf-16` default, ranges on lines containing characters outside the Basic Multilingual Plane can be off by one per such character.
- Documents are synchronized with their full text on every change. Diagnostics are published about 100 ms after typing pauses and the graph record follows about 250 ms after; requests in between analyze the current text on demand.
- References and renames only cover modules under the application source directory; definition and hover also reach files inside installed gems, but virtual modules have no location.
- References and renames answer from whatever the background index has collected so far; right after startup on a large project they can be incomplete until indexing finishes.
- Completion inspects only the current line up to the cursor. Component completion offers the constants bound in the file, not HTML tags.
- CSS class navigation is not implemented, and Ruby modules only get import-related features.
