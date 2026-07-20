// ---------------------------------------------------------------------
// OpenAPI -> MoonBit server-side scaffolding generator.
//
// Reads `components.schemas` into MoonBit structs and `paths` into a
// single `ApiHandler` trait with one method per `operationId`, plus a
// route table wiring method + path + operationId together. The caller
// implements `ApiHandler` on their own type to provide the real
// handler logic, then wires `routes()` into whatever HTTP framework
// they use, dispatching on `operation_id` to the matching method.
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
priv struct Field {
  name : String
  base_ty : String
  optional : Bool
}

///|
fn struct_fields(schema : Yaml) -> Array[Field] {
  let required = ylist(get(schema, "required")).map(ystr)
  let props = get(schema, "properties")
  let fields = []
  match props {
    YMap(entries) =>
      for kv in entries {
        let (base, nullable) = moon_type(kv.1)
        let optional = nullable || !contains_str(required, kv.0)
        fields.push({ name: kv.0, base_ty: base, optional })
      }
    _ => ()
  }
  fields
}

///|
fn gen_struct(name : String, schema : Yaml) -> String {
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
  for f in struct_fields(schema) {
    out.write_string("  " + f.name + " : " + wrap_optional(f.base_ty, f.optional) + "\n")
  }
  out.write_string("} derive(Show, Eq, ToJson, FromJson)\n")
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
fn gen_trait_method(op : Operation) -> String {
  let out = StringBuilder::new()
  if op.description != "" {
    for line in op.description.split("\n") {
      out.write_string("  /// " + line.to_owned() + "\n")
    }
  }
  let fn_name = operation_fn_name(op.operation_id)
  let params = op.params.map(fn(p) { p + " : String" })
  match op.body_type {
    Some(t) => params.push("body : " + t)
    None => ()
  }
  params.insert(0, "self : Self")
  out.write_string(
    "  " + fn_name + "(" + params.join(", ") + ") -> " + op.return_type + "\n",
  )
  out.to_string()
}

///|
/// Generates a single `ApiHandler` trait with one method per operation.
/// The caller defines a type implementing this trait to provide the
/// real handler logic, then wires `routes()` into whatever HTTP
/// framework they use, dispatching on `operation_id` to the matching
/// trait method.
fn gen_trait(ops : Array[Operation]) -> String {
  let out = StringBuilder::new()
  out.write_string("///|\n")
  out.write_string("pub trait ApiHandler {\n")
  for op in ops {
    out.write_string(gen_trait_method(op))
  }
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
/// Builds the argument list for calling `handler.<op>(...)`: one
/// `params[i]` per path parameter, plus the parsed body variable if the
/// operation takes one. Bodies are decoded and results are encoded via
/// the DTOs' derived `ToJson`/`FromJson` implementations.
fn gen_dispatch_arm(op : Operation) -> String {
  let out = StringBuilder::new()
  let fn_name = operation_fn_name(op.operation_id)
  let args = []
  for i, _ in op.params {
    args.push("params[" + i.to_string() + "]")
  }
  let respond = fn(result_var : String) -> String {
    if op.return_type == "Unit" {
      "{ status: 204, body: \"\" }"
    } else {
      "{ status: 200, body: " + result_var + ".to_json().stringify() }"
    }
  }
  out.write_string("    \"" + op.operation_id + "\" => {\n")
  match op.body_type {
    None => {
      let call = "handler." + fn_name + "(" + args.join(", ") + ")"
      if op.return_type == "Unit" {
        out.write_string("      " + call + "\n")
        out.write_string("      " + respond("") + "\n")
      } else {
        out.write_string("      let __result = " + call + "\n")
        out.write_string("      " + respond("__result") + "\n")
      }
    }
    Some(body_ty) => {
      args.push("__body")
      let call = "handler." + fn_name + "(" + args.join(", ") + ")"
      out.write_string("      match body {\n")
      out.write_string("        None => { status: 400, body: \"{\\\"error\\\":\\\"missing body\\\"}\" }\n")
      out.write_string("        Some(__raw) => try {\n")
      out.write_string(
        "          let __body : " + body_ty + " = @json.from_json(@json.parse(__raw))\n",
      )
      if op.return_type == "Unit" {
        out.write_string("          " + call + "\n")
        out.write_string("          " + respond("") + "\n")
      } else {
        out.write_string("          let __result = " + call + "\n")
        out.write_string("          " + respond("__result") + "\n")
      }
      out.write_string("        } catch {\n")
      out.write_string("          _ => { status: 400, body: \"{\\\"error\\\":\\\"invalid body\\\"}\" }\n")
      out.write_string("        }\n")
      out.write_string("      }\n")
    }
  }
  out.write_string("    }\n")
  out.to_string()
}

///|
/// Generates the `Request`/`Response` types, a path-template matcher,
/// and `handle_request`, which routes a `Request` to the matching
/// `ApiHandler` method and encodes its result as a `Response`.
fn gen_dispatcher(ops : Array[Operation]) -> String {
  let out = StringBuilder::new()
  out.write_string("///|\n")
  out.write_string("pub struct Request {\n")
  out.write_string("  method : HttpMethod\n")
  out.write_string("  path : String\n")
  out.write_string("  body : String?\n")
  out.write_string("} derive(Show, Eq)\n\n")
  out.write_string("///|\n")
  out.write_string("pub struct Response {\n")
  out.write_string("  status : Int\n")
  out.write_string("  body : String\n")
  out.write_string("} derive(Show, Eq)\n\n")
  out.write_string("///|\n")
  out.write_string("fn split_path(p : String) -> Array[String] {\n")
  out.write_string("  let out = []\n")
  out.write_string("  for part in p.split(\"/\") {\n")
  out.write_string("    out.push(part.to_owned())\n")
  out.write_string("  }\n")
  out.write_string("  out\n")
  out.write_string("}\n\n")
  out.write_string("///|\n")
  out.write_string("/// Matches a `{param}`-templated route path against a concrete request\n")
  out.write_string("/// path, returning the captured path parameters in template order.\n")
  out.write_string("fn match_path(template : String, path : String) -> Array[String]? {\n")
  out.write_string("  let tparts = split_path(template)\n")
  out.write_string("  let pparts = split_path(path)\n")
  out.write_string("  if tparts.length() != pparts.length() {\n")
  out.write_string("    return None\n")
  out.write_string("  }\n")
  out.write_string("  let params = []\n")
  out.write_string("  for i, t in tparts {\n")
  out.write_string("    let p = pparts[i]\n")
  out.write_string("    if t.has_prefix(\"{\") && t.has_suffix(\"}\") {\n")
  out.write_string("      params.push(p)\n")
  out.write_string("    } else if t != p {\n")
  out.write_string("      return None\n")
  out.write_string("    }\n")
  out.write_string("  }\n")
  out.write_string("  Some(params)\n")
  out.write_string("}\n\n")
  out.write_string("///|\n")
  out.write_string(
    "fn dispatch(handler : &ApiHandler, operation_id : String, params : Array[String], body : String?) -> Response {\n",
  )
  out.write_string("  match operation_id {\n")
  for op in ops {
    out.write_string(gen_dispatch_arm(op))
  }
  out.write_string("    _ => { status: 404, body: \"{\\\"error\\\":\\\"not found\\\"}\" }\n")
  out.write_string("  }\n}\n\n")
  out.write_string("///|\n")
  out.write_string("/// Routes a `Request` to the matching `ApiHandler` method, parsing its\n")
  out.write_string("/// body (if any) and encoding the result as a `Response`.\n")
  out.write_string("pub fn handle_request(handler : &ApiHandler, req : Request) -> Response {\n")
  out.write_string("  for route in routes() {\n")
  out.write_string("    if route.method == req.method {\n")
  out.write_string("      match match_path(route.path, req.path) {\n")
  out.write_string("        Some(params) => return dispatch(handler, route.operation_id, params, req.body)\n")
  out.write_string("        None => ()\n")
  out.write_string("      }\n")
  out.write_string("    }\n")
  out.write_string("  }\n")
  out.write_string("  { status: 404, body: \"{\\\"error\\\":\\\"not found\\\"}\" }\n")
  out.write_string("}\n")
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
    "// Code generated by mbt-gen from openapi.yaml. DO NOT EDIT.\n" +
    "//\n" +
    "// Requires \"moonbitlang/core/json\" imported as `@json` in this\n" +
    "// package's moon.pkg.json, e.g.:\n" +
    "//   { \"import\": [\"moonbitlang/core/json\"] }\n\n",
  )
  out.write_string("// --- DTOs ---\n\n")
  out.write_string(gen_schemas(root))
  out.write_string("// --- Handler Trait ---\n\n")
  out.write_string(gen_trait(ops))
  out.write_string("\n")
  out.write_string("// --- Router ---\n\n")
  out.write_string(gen_route_table(ops))
  out.write_string("\n")
  out.write_string("// --- Dispatcher ---\n\n")
  out.write_string(gen_dispatcher(ops))
  out.to_string()
}
