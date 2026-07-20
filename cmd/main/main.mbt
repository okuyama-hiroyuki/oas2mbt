///|
/// Generates MoonBit server-side scaffolding (DTOs, handler stubs, and a
/// route table) from the embedded `openapi.yaml` and prints it to stdout.
/// Run with `moon run cmd/main` from the project root.
fn main {
  println(@lib.generate_server(@lib.openapi_spec))
}
