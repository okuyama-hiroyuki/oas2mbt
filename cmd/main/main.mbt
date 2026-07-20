///|
/// Generates MoonBit server-side scaffolding (DTOs, handler stubs, and a
/// route table) from an OpenAPI spec piped in on stdin, and prints it to
/// stdout.
///
/// Usage: cat openapi.yaml | moon run cmd/main --target native > output.mbt
///
/// Reads via the C stdio primitives the MoonBit native runtime already
/// links in (`moonbit_fopen_ffi` / `moonbit_fread_ffi`), looping on
/// `fread` instead of seeking to the end for a size first — `/dev/stdin`
/// is a pipe, and `fseek` on a pipe fails.
#external
priv type FileHandle

///|
#borrow(path, mode)
extern "C" fn fopen_ffi(path : Bytes, mode : Bytes) -> FileHandle = "moonbit_fopen_ffi"

///|
extern "C" fn is_null(ptr : FileHandle) -> Int = "moonbit_is_null"

///|
#borrow(ptr)
extern "C" fn fread_ffi(
  ptr : Bytes,
  size : Int,
  nitems : Int,
  stream : FileHandle,
) -> Int = "moonbit_fread_ffi"

///|
extern "C" fn fclose_ffi(stream : FileHandle) -> Int = "moonbit_fclose_ffi"

///|
fn read_stdin() -> Bytes {
  let file = fopen_ffi(b"/dev/stdin\x00", b"rb\x00")
  guard is_null(file) == 0 else { abort("failed to open /dev/stdin") }
  let buf = @buffer.new(size_hint=65536)
  let chunk = Bytes::make(65536, 0)
  let mut n = fread_ffi(chunk, 1, chunk.length(), file)
  while n > 0 {
    buf.write_bytes(chunk[0:n])
    n = fread_ffi(chunk, 1, chunk.length(), file)
  }
  fclose_ffi(file) |> ignore
  buf.to_bytes()
}

///|
fn main {
  let spec = @encoding.decoder(UTF8).decode_lossy(read_stdin()[:])
  println(@lib.generate_server(spec))
}
