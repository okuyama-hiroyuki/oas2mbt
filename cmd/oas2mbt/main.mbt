///|
/// Generates MoonBit server-side scaffolding (DTOs, an `ApiHandler`
/// trait, and a route table) from an OpenAPI spec piped in on stdin,
/// and prints it to stdout.
///
/// Usage: cat openapi.yaml | moon run cmd/main --target native > output.mbt
async fn main {
  let spec = @stdio.stdin.read_all().text()
  println(@lib.generate_server(spec))
}
