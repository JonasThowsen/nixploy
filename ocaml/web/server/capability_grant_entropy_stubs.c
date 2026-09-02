#define CAML_NAME_SPACE
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/unixsupport.h>
#include <errno.h>
#include <sys/random.h>
#include <unistd.h>

CAMLprim value nixploy_capability_grant_getrandom(value length_value)
{
  CAMLparam1(length_value);
  CAMLlocal1(result);
  long requested = Long_val(length_value);
  if (requested < 0 || requested > 4096) caml_invalid_argument("getrandom length");
  result = caml_alloc_string(requested);
  unsigned char *buffer = Bytes_val(result);
  long received = 0;
  while (received < requested) {
    ssize_t count = getrandom(buffer + received, (size_t)(requested - received), 0);
    if (count > 0) received += count;
    else if (count < 0 && errno == EINTR) continue;
    else caml_uerror("getrandom", Nothing);
  }
  CAMLreturn(result);
}
