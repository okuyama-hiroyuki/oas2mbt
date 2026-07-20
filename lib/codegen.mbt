// ---------------------------------------------------------------------
// OpenAPI -> MoonBit server-side scaffolding generator.
//
// Reads `components.schemas` into MoonBit structs and `paths` into one
// handler-function stub per `operationId`, plus a route table wiring
// method + path + operationId together. Handler bodies are left as
// `abort(...)` stubs; the caller fills in real logic and, if desired,
// wires `routes()` into whatever HTTP framework they use.
// ---------------------------------------------------------------------

///|
fn last_segment(s : String, sep : String) -> String {
  let parts = s.split(sep).collect()
  if parts.length() == 0 {
    s
  } else {
    parts[parts.length() - 1].to_owned()
  }
}

///|
fn schema_ref_name(y : Yaml) -> String? {
  match ymap_get(y, "$ref") {
    Some(YStr(r)) => Some(last_segment(r, "/"))
    _ => None
  }
}

///|
/// Resolves the MoonBit type of a schema fragment and whether it should
/// be treated as nullable (from an `anyOf [T, null]` pattern).
fn moon_type(schema : Yaml) -> (String, Bool) {
  match schema_ref_name(schema) {
    Some(name) => return (reserved_type_name(name), false)
    None => ()
  }
  match ymap_get(schema, "anyOf") {
    Some(YList(alts)) => {
      let mut nullable = false
      let mut other = "String"
      for alt in alts {
        if ystr(get(alt, "type")) == "null" {
          nullable = true
        } else {
          let (t, _) = moon_type(alt)
          other = t
        }
      }
      return (other, nullable)
    }
    _ => ()
  }
  let t = ystr(get(schema, "type"))
  if t == "array" {
    let (it, _) = moon_type(get(schema, "items"))
    ("Array[" + it + "]", false)
  } else if t == "string" {
    ("String", false)
  } else if t == "boolean" {
    ("Bool", false)
  } else if t == "integer" {
    ("Int", false)
  } else {
    ("String", false)
  }
}

///|
fn contains_str(arr : Array[String], v : String) -> Bool {
  for x in arr {
    if x == v {
      return true
    }
  }
  false
}

///|
/// UpperCamel/lowerCamel -> snake_case.
fn to_snake_case(s : String) -> String {
  let out = StringBuilder::new()
  let chars = s.to_array()
  for i, c in chars {
    if c.to_int() >= 65 && c.to_int() <= 90 {
      if i != 0 {
        out.write_char('_')
      }
      out.write_char((c.to_int() + 32).unsafe_to_char())
    } else {
      out.write_char(c)
    }
  }
  out.to_string()
}

///|
/// `Apps_setDomain` -> `apps_set_domain`.
fn operation_fn_name(operation_id : String) -> String {
  match operation_id.split_once("_") {
    Some((prefix, rest)) =>
      to_snake_case(prefix.to_owned()) + "_" + to_snake_case(rest.to_owned())
    None => to_snake_case(operation_id)
  }
}

///|
fn wrap_optional(ty : String, optional : Bool) -> String {
  if optional && !ty.has_suffix("?") {
    ty + "?"
  } else {
    ty
  }
}

///|
fn gen_struct(name : String, schema : Yaml) -> String {
  let required = ylist(get(schema, "required")).map(ystr)
  let props = get(schema, "properties")
  let out = StringBuilder::new()
  out.write_string("///|\n")
  match schema {
    YMap(_) =>
      match ymap_get(schema, "description") {
        Some(YStr(d)) =>
          for line in d.split("\n") {
            out.write_string("/// " + line.to_owned() + "\n")
          }
        _ => ()
      }
    _ => ()
  }
  out.write_string("pub struct " + name + " {\n")
  match props {
    YMap(entries) =>
      for kv in entries {
        let (base, nullable) = moon_type(kv.1)
        let optional = nullable || !contains_str(required, kv.0)
        let ty = wrap_optional(base, optional)
        out.write_string("  " + kv.0 + " : " + ty + "\n")
      }
    _ => ()
  }
  out.write_string("} derive(Show, Eq)\n")
  out.to_string()
}

///|
/// A handful of identifiers MoonBit reserves for the language itself
/// (e.g. the `Error` suberror type); schemas using these names are
/// suffixed with `Dto` to stay a valid declaration.
fn reserved_type_name(name : String) -> String {
  if name == "Error" || name == "Result" || name == "Option" {
    name + "Dto"
  } else {
    name
  }
}

///|
fn gen_schemas(root : Yaml) -> String {
  let schemas = get(get(root, "components"), "schemas")
  let out = StringBuilder::new()
  match schemas {
    YMap(entries) =>
      for kv in entries {
        out.write_string(gen_struct(reserved_type_name(kv.0), kv.1))
        out.write_string("\n")
      }
    _ => ()
  }
  out.to_string()
}

///|
priv enum HttpMethod {
  Get
  Post
  Put
  Delete
  Patch
  Head
  Options
  Trace
}

///|
fn http_method_name(m : HttpMethod) -> String {
  match m {
    Get => "Get"
    Post => "Post"
    Put => "Put"
    Delete => "Delete"
    Patch => "Patch"
    Head => "Head"
    Options => "Options"
    Trace => "Trace"
  }
}

///|
fn http_method_of(s : String) -> HttpMethod {
  match s {
    "get" => Get
    "post" => Post
    "put" => Put
    "delete" => Delete
    "patch" => Patch
    "head" => Head
    "options" => Options
    "trace" => Trace
    _ => abort("unknown http method: " + s)
  }
}

///|
priv struct Operation {
  operation_id : String
  http_method : HttpMethod
  path : String
  description : String
  params : Array[String]
  body_type : String?
  return_type : String
}

///|
fn response_type(op : Yaml) -> String {
  let responses = get(op, "responses")
  let success_keys = ["200", "201"]
  for key in success_keys {
    match ymap_get(responses, key) {
      Some(resp) => {
        let content = get(get(resp, "content"), "application/json")
        match ymap_get(content, "schema") {
          Some(schema) => {
            let t = ystr(get(schema, "type"))
            if t == "array" {
              let (it, _) = moon_type(get(schema, "items"))
              return "Array[" + it + "]"
            }
            let (t2, _) = moon_type(schema)
            return t2
          }
          None => ()
        }
      }
      None => ()
    }
  }
  "Unit"
}

///|
fn collect_operations(root : Yaml) -> Array[Operation] {
  let ops = []
  match get(root, "paths") {
    YMap(paths) =>
      for pkv in paths {
        let path = pkv.0
        match pkv.1 {
          YMap(methods) =>
            for mkv in methods {
              let http_method = http_method_of(mkv.0)
              let op = mkv.1
              let op_id = ystr(get(op, "operationId"))
              if op_id == "" {
                continue
              }
              let params = []
              for p in ylist(get(op, "parameters")) {
                if ystr(get(p, "in")) == "path" {
                  params.push(ystr(get(p, "name")))
                }
              }
              let body_type = match ymap_get(op, "requestBody") {
                Some(rb) => {
                  let content = get(get(rb, "content"), "application/json")
                  match schema_ref_name(get(content, "schema")) {
                    Some(n) => Some(reserved_type_name(n))
                    None => None
                  }
                }
                None => None
              }
              ops.push({
                operation_id: op_id,
                http_method,
                path,
                description: ystr(get(op, "description")),
                params,
                body_type,
                return_type: response_type(op),
              })
            }
          _ => ()
        }
      }
    _ => ()
  }
  ops
}

///|
fn gen_handler(op : Operation) -> String {
  let out = StringBuilder::new()
  if op.description != "" {
    for line in op.description.split("\n") {
      out.write_string("/// " + line.to_owned() + "\n")
    }
  }
  out.write_string("///|\n")
  let fn_name = operation_fn_name(op.operation_id)
  let params = op.params.map(fn(p) { p + " : String" })
  match op.body_type {
    Some(t) => params.push("body : " + t)
    None => ()
  }
  out.write_string(
    "pub fn " +
    fn_name +
    "(" +
    params.join(", ") +
    ") -> " +
    op.return_type +
    " {\n",
  )
  out.write_string("  abort(\"not implemented: " + op.operation_id + "\")\n")
  out.write_string("}\n")
  out.to_string()
}

///|
fn gen_route_table(ops : Array[Operation]) -> String {
  let out = StringBuilder::new()
  out.write_string("///|\n")
  out.write_string("pub enum HttpMethod {\n")
  out.write_string("  Get\n")
  out.write_string("  Post\n")
  out.write_string("  Put\n")
  out.write_string("  Delete\n")
  out.write_string("  Patch\n")
  out.write_string("  Head\n")
  out.write_string("  Options\n")
  out.write_string("  Trace\n")
  out.write_string("} derive(Show, Eq)\n\n")
  out.write_string("///|\n")
  out.write_string("pub struct Route {\n")
  out.write_string("  method : HttpMethod\n")
  out.write_string("  path : String\n")
  out.write_string("  operation_id : String\n")
  out.write_string("} derive(Show, Eq)\n\n")
  out.write_string("///|\n")
  out.write_string("pub fn routes() -> Array[Route] {\n  [\n")
  for op in ops {
    out.write_string(
      "    { method: " +
      http_method_name(op.http_method) +
      ", path: \"" +
      op.path +
      "\", operation_id: \"" +
      op.operation_id +
      "\" },\n",
    )
  }
  out.write_string("  ]\n}\n")
  out.to_string()
}

///|
/// Generates MoonBit server-side scaffolding (DTO structs, one handler
/// stub per `operationId`, and a route table) from an OpenAPI 3.1
/// document written in the plain block style handled by `parse_yaml`.
pub fn generate_server(spec : String) -> String {
  let root = parse_yaml(spec)
  let ops = collect_operations(root)
  let out = StringBuilder::new()
  out.write_string(
    "// Code generated by mbt-gen from openapi.yaml. DO NOT EDIT.\n\n",
  )
  out.write_string("// --- DTOs ---\n\n")
  out.write_string(gen_schemas(root))
  out.write_string("// --- Handlers ---\n\n")
  for op in ops {
    out.write_string(gen_handler(op))
    out.write_string("\n")
  }
  out.write_string("// --- Router ---\n\n")
  out.write_string(gen_route_table(ops))
  out.to_string()
}
