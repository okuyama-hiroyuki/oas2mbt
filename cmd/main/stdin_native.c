#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <moonbit.h>

MOONBIT_FFI_EXPORT moonbit_bytes_t
mbt_gen_read_stdin_ffi(void) {
  size_t cap = 65536;
  size_t len = 0;
  char *buf = malloc(cap);
  if (buf == NULL) {
    moonbit_bytes_t empty = moonbit_make_bytes(0, 0);
    return empty;
  }
  size_t n;
  while ((n = fread(buf + len, 1, cap - len, stdin)) > 0) {
    len += n;
    if (len == cap) {
      cap *= 2;
      char *next = realloc(buf, cap);
      if (next == NULL) {
        free(buf);
        moonbit_bytes_t empty = moonbit_make_bytes(0, 0);
        return empty;
      }
      buf = next;
    }
  }
  moonbit_bytes_t result = moonbit_make_bytes(len, 0);
  memcpy(result, buf, len);
  free(buf);
  return result;
}
