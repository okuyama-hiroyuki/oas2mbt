///|
/// Generates MoonBit server-side scaffolding (DTOs, handler stubs, and a
/// route table) from an OpenAPI spec piped in on stdin, and prints it to
/// stdout.
///
/// Usage: cat openapi.yaml | moon run cmd/main --target native > output.mbt
extern "C" fn read_stdin_ffi() -> Bytes = "mbt_gen_read_stdin_ffi"

///|
fn main {
  let spec = @encoding.decoder(UTF8).decode_lossy(read_stdin_ffi()[:])
  println(@lib.generate_server(spec))
}
