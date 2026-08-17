use lightningcss::dependencies::DependencyOptions;
use lightningcss::{
    selector::{Component, Selector},
    stylesheet::{MinifyOptions, ParserOptions, PrinterOptions, StyleSheet},
    visitor::{Visit, VisitTypes, Visitor},
};
use magnus::{
    exception::ExceptionClass, function, gc::register_mark_object, prelude::*, value::Lazy, Error,
    RHash, RModule, Ruby, TryConvert,
};
use parcel_sourcemap::SourceMap;
use std::{collections::HashMap, convert::Infallible};

static PARSE_ERROR: Lazy<ExceptionClass> = Lazy::new(|ruby| {
    let ex = ruby
        .class_object()
        .const_get::<_, RModule>("Klenod")
        .unwrap()
        .const_get::<_, RModule>("Plugin")
        .unwrap()
        .const_get::<_, RModule>("CSS")
        .unwrap()
        .const_get("ParseError")
        .unwrap();
    register_mark_object(ex);
    ex
});

#[derive(Clone)]
struct TransformOptions {
    component: String,
    hash: String,
    transform_names: bool,
    class_pattern: String,
    tag_pattern: String,
}

struct TransformNamesVisitor<'a> {
    options: TransformOptions,
    classes: &'a mut HashMap<String, String>,
    elements: &'a mut HashMap<String, String>,
}

impl<'a, 'i> Visitor<'i> for TransformNamesVisitor<'a> {
    type Error = Infallible;

    fn visit_types(&self) -> VisitTypes {
        VisitTypes::RULES
    }

    fn visit_selector(&mut self, selector: &mut Selector<'i>) -> Result<(), Self::Error> {
        for component in selector.iter_mut_raw_match_order() {
            match component {
                Component::Class(class_name) => {
                    let original = class_name.to_string();
                    let formatted = format_selector(
                        &self.options.class_pattern,
                        &self.options.component,
                        &original,
                        &self.options.hash,
                    );
                    self.classes.insert(original, formatted.clone());
                    if self.options.transform_names {
                        *component = Component::Class(formatted.into());
                    }
                }
                Component::LocalName(local_name) => {
                    let original = local_name.name.to_string();
                    let formatted = format_selector(
                        &self.options.tag_pattern,
                        &self.options.component,
                        &original,
                        &self.options.hash,
                    );
                    self.elements.insert(original, formatted.clone());
                    if self.options.transform_names {
                        *component = Component::Class(formatted.into());
                    }
                }
                _ => {}
            }
        }

        Ok(())
    }
}

fn transform_native(ruby: &Ruby, source: String, filename: String, options: RHash) -> Result<RHash, Error> {
    let minify = hash_fetch_bool(ruby, options, "minify", true)?;
    let transform_names = hash_fetch_bool(ruby, options, "transform_names", true)?;
    let class_pattern = hash_fetch_string(ruby, options, "class_pattern", "[component].[local]?[hash]")?;
    let tag_pattern = hash_fetch_string(ruby, options, "tag_pattern", "[component]_[local]?[hash]")?;
    let mut stylesheet = parse_stylesheet(ruby, &filename, &source)?;
    let mut classes = HashMap::new();
    let mut elements = HashMap::new();
    let selector_options = TransformOptions {
        component: component_name(&filename),
        hash: hash(&source),
        transform_names,
        class_pattern,
        tag_pattern,
    };

    let _ = stylesheet.visit(&mut TransformNamesVisitor {
        options: selector_options,
        classes: &mut classes,
        elements: &mut elements,
    });

    let mut source_map = SourceMap::new("/");
    source_map.add_source(&filename);
    source_map.set_source_content(0, &source).unwrap();

    if minify {
        stylesheet.minify(MinifyOptions::default()).unwrap();
    }

    let result = stylesheet
        .to_css(PrinterOptions {
            analyze_dependencies: Some(DependencyOptions::default()),
            minify,
            source_map: Some(&mut source_map),
            ..PrinterOptions::default()
        })
        .unwrap();

    let hash = ruby.hash_new();
    hash.aset("code", result.code)?;
    hash.aset("classes", string_map_to_hash(ruby, classes)?)?;
    hash.aset("elements", string_map_to_hash(ruby, elements)?)?;
    hash.aset("source_map", source_map.to_json(None).ok())?;
    hash.aset(
        "dependencies",
        serde_json::from_str::<serde_json::Value>(&serde_json::to_string(&result.dependencies.unwrap()).unwrap())
            .unwrap()
            .to_string(),
    )?;
    hash.aset(
        "exports",
        serde_json::from_str::<serde_json::Value>(&serde_json::to_string(&result.exports.unwrap()).unwrap())
            .unwrap()
            .to_string(),
    )?;
    Ok(hash)
}

fn minify_native(ruby: &Ruby, source: String, filename: String) -> Result<String, Error> {
    let mut stylesheet = parse_stylesheet(ruby, &filename, &source)?;
    stylesheet.minify(MinifyOptions::default()).unwrap();

    Ok(stylesheet
        .to_css(PrinterOptions {
            analyze_dependencies: Some(DependencyOptions::default()),
            minify: true,
            ..PrinterOptions::default()
        })
        .unwrap()
        .code)
}

fn serialize_native(ruby: &Ruby, source: String, filename: String) -> Result<String, Error> {
    let stylesheet = parse_stylesheet(ruby, &filename, &source)?;
    Ok(serde_json::to_string(&stylesheet).unwrap())
}

fn parse_stylesheet<'i>(ruby: &Ruby, filename: &str, source: &'i str) -> Result<StyleSheet<'i>, Error> {
    StyleSheet::parse(
        source,
        ParserOptions {
            filename: filename.to_string(),
            css_modules: Some(lightningcss::css_modules::Config {
                pattern: lightningcss::css_modules::Pattern::parse("[local]").unwrap(),
                dashed_idents: false,
                animation: false,
                grid: false,
                container: false,
                custom_idents: false,
                pure: false,
            }),
            ..ParserOptions::default()
        },
    )
    .map_err(|error| Error::new(ruby.get_inner(&PARSE_ERROR), error.to_string()))
}

fn hash_fetch_bool(_ruby: &Ruby, hash: RHash, key: &str, default: bool) -> Result<bool, Error> {
    match hash.get(key) {
        Some(value) => bool::try_convert(value),
        None => Ok(default),
    }
}

fn hash_fetch_string(_ruby: &Ruby, hash: RHash, key: &str, default: &str) -> Result<String, Error> {
    match hash.get(key) {
        Some(value) => String::try_convert(value),
        None => Ok(default.to_string()),
    }
}

fn string_map_to_hash(ruby: &Ruby, map: HashMap<String, String>) -> Result<RHash, Error> {
    let hash = ruby.hash_new();
    for (key, value) in map {
        hash.aset(key, value)?;
    }
    Ok(hash)
}

fn component_name(filename: &str) -> String {
    std::path::Path::new(filename)
        .with_extension("")
        .display()
        .to_string()
}

fn format_selector(pattern: &str, component: &str, local: &str, hash: &str) -> String {
    pattern
        .replace("[component]", component)
        .replace("[local]", local)
        .replace("[hash]", hash)
}

fn hash(source: &str) -> String {
    use base64::{engine::general_purpose, Engine as _};
    use sha2::{Digest, Sha256};

    let mut hasher = Sha256::new();
    hasher.update(source);
    general_purpose::URL_SAFE_NO_PAD
        .encode(hasher.finalize())
        .get(0..8)
        .unwrap()
        .to_string()
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let klenod = ruby.define_module("Klenod")?;
    let plugin = klenod.define_module("Plugin")?;
    let css = plugin.define_module("CSS")?;
    let native = css.define_module("Native")?;
    native.define_singleton_method("transform_native", function!(transform_native, 3))?;
    native.define_singleton_method("minify_native", function!(minify_native, 2))?;
    native.define_singleton_method("serialize_native", function!(serialize_native, 2))?;
    Ok(())
}
