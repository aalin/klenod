# Graph And Plugin Phases

Klenod separates graph collection from module evaluation.

## Graph States

A module can be collected without being evaluated.

- Collected: Klenod has read the source, transformed it, resolved imports, collected dependency records, emitted assets, and stored a `ModuleRecord`.
- Evaluated: Klenod has instantiated a `Klenod::Runtime::Mod` for that record and Ruby top-level code has run.

`context.entry(...)` and `context.collect(...)` collect modules and return handles without evaluating app code. `entry.exports`, `entry.call(...)`, `context.exports(...)`, and `context.evaluate(...)` evaluate modules on demand.

Build mode only needs collected records. It serializes those records into runtime module specs so production can evaluate them later through `Klenod::Runtime::Bundle`.

## Plugin Hook Phases

Plugin hooks belong to different phases:

- `resolve(dependency, context)` maps an import specifier to a module id.
- `load(module_id, context)` provides source for virtual modules or custom files.
- `transform(module_id, code, context)` rewrites source and records dependencies, assets, metadata, source maps, and watched patterns.
- `finalize(module_id, result, resolved_dependencies, dependency_records, context)` adjusts a transform after eager dependency records are collected.
- `import_value(resolved_dependency, record, context)` provides the value seen by an evaluated module in development.
- `runtime_import_value(resolved_dependency, record, context)` provides the value serialized into runtime bundles.

`transform` and `finalize` are graph collection hooks. They must not require evaluated app exports.

## `import_value`

`import_value` is used when Ruby code is evaluated in the build/dev process.

Example: a Ruby or Haml module imports a CSS file in development:

```ruby
Styles = import("./page.css")
```

When that importing module is evaluated, Klenod asks plugins for the import value. The CSS plugin returns the class-name map from the collected CSS record. The evaluated module receives that value as `Styles`.

This hook can depend on build/dev objects such as `Klenod::Build::Asset` and live collected records. It should not be used for production bundle serialization.

## `runtime_import_value`

`runtime_import_value` is used while building a runtime bundle.

Build mode does not evaluate app modules, so it cannot ask evaluated exports for import values. Instead, it serializes runtime module specs and stores any special import value metadata directly in the bundle.

Example: CSS imports need the same class-name map at runtime. The CSS plugin therefore also provides `runtime_import_value`, and the runtime bundle stores that map in the import spec. When production evaluates the importing module later, the runtime import resolves to the stored class map without requiring the CSS plugin.

Plugins should implement `runtime_import_value` only for values that are safe to serialize and available from collected records or transform metadata.

## Rule Of Thumb

Use `import_value` for development-time evaluated imports.

Use `runtime_import_value` for production bundle import values.

Do not make `runtime_import_value` call `import_value` unless that is explicitly safe for the plugin. Runtime serialization must not depend on evaluated build-time exports.
