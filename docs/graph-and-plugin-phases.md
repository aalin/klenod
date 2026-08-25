# Graph and Plugin Phases

Klenod keeps graph collection separate from module evaluation.

## Graph States

A module can be collected without evaluation.

- Collected: Klenod reads the source, transforms it, resolves its imports, collects dependency records, emits assets, and stores a `ModuleRecord`.
- Evaluated: Klenod creates a `Klenod::Runtime::Mod` for the record and runs the top-level Ruby code.

`context.entry(...)` and `context.collect(...)` collect modules. They return handles and do not evaluate application code.

These methods evaluate modules when necessary:

- `entry.exports`
- `entry.call(...)`
- `context.exports(...)`
- `context.evaluate(...)`

Build mode only needs collected records. It serializes these records as runtime module specifications. Production evaluates the modules through `Klenod::Runtime::Bundle`.

## Plugin Hook Phases

Plugin hooks run during different phases:

- `resolve(dependency, context)` maps an import specifier to a canonical module ID.
- `load(module_id, context)` supplies source code for virtual modules or custom files.
- `transform(module_id, code, context)` changes source code and records dependencies, assets, metadata, source maps, and watched patterns.
- `finalize(module_id, result, resolved_dependencies, dependency_records, context)` changes a transform after Klenod collects eager dependency records.
- `import_value(resolved_dependency, record, context)` supplies the value that an evaluated module receives during development.
- `runtime_import_value(resolved_dependency, record, context)` supplies the value that Klenod serializes in a runtime bundle.
- `invalidate_module_ids(paths, context)` supplies more module IDs to invalidate after source paths change.

The `resolve`, `load`, `transform`, and `finalize` hooks collect the graph. These hooks must not require evaluated application exports.

Module IDs use URI-like schemes. Application source files use IDs such as `app:/path/to/file.rb`. Virtual modules use IDs such as `virtual:/name.rb`.

Plugin-owned module trees can use IDs such as `gem://gem-name/path.rb`. Klenod resolves relative import specifiers from the importer with URL-style rules. Plugins can resolve non-application schemes before Klenod searches the application file system.

## `import_value`

Klenod uses `import_value` when it evaluates Ruby code during development.

For example, a Ruby or Haml module can import a CSS file:

```ruby
Styles = import("./+page.css")
```

During evaluation, Klenod asks each plugin for the import value. The CSS plugin returns `Exports::Default` from the generated CSS module.

This value is a `ClassNames` object. It contains the scoped class names. The evaluated module receives this object as `Styles`.

The hook can use build and development objects. Examples include `Klenod::Build::Asset` objects and live collected records. Do not use this hook for production bundle serialization.

A plugin can also use `import_value` when callers must not receive the complete `Exports` module.

For example, a plugin for `.thing` files can generate a Ruby module with a `Default` export:

```ruby
Default = Thing.new(name: "Demo")
```

Without an import hook, `import` returns the complete generated exports module:

```ruby
Thing = import("./demo.thing")
# => Mod("app:/demo.thing")::Exports
```

The plugin can return `Exports::Default` during development:

```ruby
def import_value(_resolved_dependency, record, context)
  return nil unless record.id.extname == ".thing"

  context.mods.fetch(record.id).const_get(:Exports)::Default
end
```

The caller then receives the default object:

```ruby
Thing = import("./demo.thing")
# => #<Thing name="Demo">
```

A `nil` return value means that the plugin does not supply an import value. Klenod then asks the next plugin.

If no plugin supplies a value, Klenod returns the target module's `Exports` module.

## `runtime_import_value`

Klenod uses `runtime_import_value` when it builds a runtime bundle.

Build mode does not evaluate application modules. Thus, it cannot get import values from evaluated exports. It serializes runtime module specifications and special import-value metadata instead.

For example, a generated CSS module creates a `ClassNames` object as `Exports::Default`. The CSS plugin returns a `Klenod::Runtime::DefaultImport` instruction for the bundle.

During production evaluation, the runtime evaluates the CSS module. It then returns `Exports::Default` to the importer. Production does not require the CSS plugin.

Only use `runtime_import_value` for values that are safe to serialize. These values must be available from collected records or transform metadata.

The runtime bundle does not need the `.thing` build plugin to use `Exports::Default`. The plugin can return a small serializable instruction:

```ruby
def runtime_import_value(_resolved_dependency, record, _context)
  return Klenod::Runtime::DefaultImport.new(:Default) if record.id.extname == ".thing"

  super
end
```

During bundle execution, the runtime uses this instruction to evaluate the target module. It reads `Exports` and returns `Exports::Default` to the importer.

The two hooks answer the same question in different environments:

```text
development evaluation:
  import_value -> current Ruby value

bundle serialization:
  runtime_import_value -> serializable instruction or data
```

Some plugins return plain serializable data from both hooks. Data-format plugins use the hooks as follows:

- `import_value` returns the evaluated `Exports::Default` value.
- `runtime_import_value` returns the same parsed value from collected metadata.

Other plugins return a live value from `import_value`. They return a `Klenod::Runtime::DefaultImport` marker from `runtime_import_value`.

## Rule of Thumb

Use `import_value` for evaluated imports during development.

Use `runtime_import_value` for import values in production bundles.

Do not make `runtime_import_value` call `import_value` unless the plugin can do this safely. Runtime serialization must not depend on evaluated build-time exports.
