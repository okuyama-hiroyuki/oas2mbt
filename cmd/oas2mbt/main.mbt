///|
let usage : String =
  #|Usage: oas2mbt < openapi.yaml > output.mbt
  #|
  #|Generates MoonBit server-side scaffolding (DTOs, an ApiHandler trait,
  #|and a route table) from an OpenAPI spec read from stdin, and prints
  #|it to stdout.
  #|
  #|Options:
  #|  -h, --help    Show this help message and exit

///|
/// Generates MoonBit server-side scaffolding (DTOs, an `ApiHandler`
/// trait, and a route table) from an OpenAPI spec piped in on stdin,
/// and prints it to stdout.
///
/// Usage: cat openapi.yaml | moon run cmd/main --target native > output.mbt
async fn main {
  let args = @sys.get_cli_args()
  if args.iter().any(a => a == "-h" || a == "--help") {
    println(usage)
    return
  }
  let spec = @stdio.stdin.read_all().text()
  println(@lib.generate_server(spec))
}
