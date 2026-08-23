#define _GNU_SOURCE
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/unixsupport.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/select.h>
#include <time.h>
#include <signal.h>
#include <unistd.h>

static int retry_fsync(int fd) {
  int result;
  do result = fsync(fd); while (result == -1 && errno == EINTR);
  return result;
}

static int retry_close(int fd) {
  int result;
  do result = close(fd); while (result == -1 && errno == EINTR);
  return result;
}

static int retry_unlinkat(int directory, const char *name) {
  int result;
  do result = unlinkat(directory, name, 0); while (result == -1 && errno == EINTR);
  return result;
}

static int write_all(int fd, const char *contents, size_t length) {
  size_t offset = 0;
  while (offset < length) {
    ssize_t count = write(fd, contents + offset, length - offset);
    if (count > 0) {
      offset += (size_t)count;
    } else if (count == -1 && errno == EINTR) {
      continue;
    } else {
      if (count == 0) errno = EIO;
      return -1;
    }
  }
  return 0;
}

/* Deterministic fault injection for the durable-state primitives below.
   g_ops_until_fault lets exactly [n] counted write/fsync/unlink attempts
   succeed, then fails the next one once with EIO across
   caml_nixploy_target_lease_clear_clean_receipt,
   caml_nixploy_target_lease_mark_dirty,
   caml_nixploy_target_lease_write_clean_receipt, and
   caml_nixploy_target_lease_retire_dirty, in call order.  Exactly [n] counted
   operations succeed, then the next one fails once with EIO and injection
   disables itself.
   A negative value disables injection entirely. */
static long g_ops_until_fault = -1;

static int maybe_counted_fault(void) {
  if (g_ops_until_fault == 0) {
    g_ops_until_fault = -1;
    errno = EIO;
    return -1;
  }
  if (g_ops_until_fault > 0) g_ops_until_fault--;
  return 0;
}

CAMLprim value caml_nixploy_target_lease_inject_failure_after(value ops) {
  CAMLparam1(ops);
  g_ops_until_fault = Long_val(ops);
  CAMLreturn(Val_unit);
}

CAMLprim value caml_nixploy_target_lease_ignore_sigpipe(value unit) {
  CAMLparam1(unit);
  if (signal(SIGPIPE, SIG_IGN) == SIG_ERR) uerror("ignore SIGPIPE", Nothing);
  CAMLreturn(Val_unit);
}

CAMLprim value caml_nixploy_target_lease_peer_uid(value fd_value) {
  CAMLparam1(fd_value);
  struct ucred credential;
  socklen_t size = sizeof(credential);
  int fd = Int_val(fd_value);
  if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credential, &size) == -1)
    uerror("getsockopt(SO_PEERCRED)", Nothing);
  CAMLreturn(Val_int(credential.uid));
}

CAMLprim value caml_nixploy_target_lease_socket_error(value fd_value) {
  CAMLparam1(fd_value);
  int error = 0;
  socklen_t size = sizeof(error);
  int fd = Int_val(fd_value);
  if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == -1)
    uerror("getsockopt(SO_ERROR)", Nothing);
  CAMLreturn(Val_int(error));
}

CAMLprim value caml_nixploy_target_lease_monotonic_clock(value unit) {
  CAMLparam1(unit);
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) == -1)
    uerror("clock_gettime(CLOCK_MONOTONIC)", Nothing);
  CAMLreturn(caml_copy_double((double)now.tv_sec + (double)now.tv_nsec / 1e9));
}

CAMLprim value caml_nixploy_target_lease_fd_is_selectable(value fd_value) {
  CAMLparam1(fd_value);
  CAMLreturn(Val_bool(Int_val(fd_value) >= 0 && Int_val(fd_value) < FD_SETSIZE));
}

static int open_private_directory(const char *root) {
  int directory = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (directory == -1) return -1;
  struct stat status;
  if (fstat(directory, &status) == -1 || !S_ISDIR(status.st_mode)) {
    int saved = errno;
    close(directory);
    errno = saved ? saved : ENOTDIR;
    return -1;
  }
  return directory;
}

/* Once a marker or receipt has been created we never unlink or overwrite it on
   an error path.  Best-effort sync keeps the conservative evidence survive as
   many failure modes as possible; ambiguity is resolved by refusing to start
   rather than by restoring or clearing anything. */
static void preserve_files(int a, int b, int directory) {
  if (a >= 0) { (void)retry_fsync(a); (void)retry_close(a); }
  if (b >= 0) { (void)retry_fsync(b); (void)retry_close(b); }
  if (directory >= 0) { (void)retry_fsync(directory); (void)close(directory); }
}

/* Durable state machine (see ocaml/lib/target_lease_state.mli):

   mark_dirty          : create "<name>" containing "dirty <generation>\n",
                         fsync file, fsync directory.
   write_clean_receipt : create "<name>.clean" containing "clean <generation>\n"
                         (idempotent when an identical valid receipt exists),
                         fsync file, fsync directory.  The dirty marker is NOT
                         touched: from this moment any surviving uncertainty is
                         observable as both files being present.
   retire_dirty        : verify the marker reads exactly "dirty <generation>\n",
                         unlink it, fsync directory.  Never restores anything:
                         if the fsync is lost the directory either still holds
                         both files (blocked) or converges to clean-only, which
                         matches the truth because both prior writes were
                         durable.

   Every failure above reports an error and leaves existing evidence in place.
   No code path removes the only copy of unclean evidence. */

static value caml_nixploy_target_lease_read_exact(int directory, const char *name, char *buffer, size_t capacity);

value caml_nixploy_target_lease_read_exact(int directory, const char *name, char *buffer, size_t capacity) {
  int fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (fd == -1) return Val_false;
  size_t offset = 0;
  for (;;) {
    ssize_t count = read(fd, buffer + offset, capacity - offset);
    if (count > 0) {
      offset += (size_t)count;
      if (offset > capacity) break;
    } else if (count == 0) {
      close(fd);
      buffer[offset] = '\0';
      return Val_true;
    } else if (errno != EINTR) {
      break;
    }
  }
  close(fd);
  uerror("read durable state entry", Nothing);
}

static void fail_with_saved(int saved, int directory, const char *tag, const char *name) {
  if (directory >= 0) close(directory);
  unix_error(saved, (char *)tag, caml_copy_string(name));
}

/* Acquire-time cleanup: retire a stale clean receipt from a previous
   completed lease before a new dirty marker is created.  ENOENT is success.
   Removing clean evidence is always safe: it is never the only evidence of
   possibly unclean ownership. */
CAMLprim value caml_nixploy_target_lease_clear_clean_receipt(value root, value name) {
  CAMLparam2(root, name);
  const char *name_string = String_val(name);
  char receipt_name[256];
  if (snprintf(receipt_name, sizeof(receipt_name), "%s.clean", name_string) >= (int)sizeof(receipt_name))
    fail_with_saved(EINVAL, -1, "render receipt name", name_string);
  int directory = open_private_directory(String_val(root));
  if (directory == -1) uerror("open private state directory", root);
  int result = retry_unlinkat(directory, receipt_name);
  if (result == -1 && errno != ENOENT)
    fail_with_saved(errno, directory, "unlink clean receipt", receipt_name);
  errno = 0;
  if (maybe_counted_fault() == -1 || retry_fsync(directory) == -1) {
    int saved = errno;
    preserve_files(-1, -1, directory);
    unix_error(saved, (char *)"fsync state directory after clearing clean receipt",
               caml_copy_string(receipt_name));
  }
  if (close(directory) == -1) uerror("close private state directory", root);
  CAMLreturn(Val_unit);
}

CAMLprim value caml_nixploy_target_lease_mark_dirty(value root, value name, value generation) {
  CAMLparam3(root, name, generation);
  const char *name_string = String_val(name);
  char line[128];
  int length = snprintf(line, sizeof(line), "dirty %s\n", String_val(generation));
  if (length <= 0 || (size_t)length >= sizeof(line))
    fail_with_saved(EINVAL, -1, "render dirty marker", name_string);
  int directory = open_private_directory(String_val(root));
  if (directory == -1) uerror("open private state directory", root);
  int marker = openat(directory, name_string,
                      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (marker == -1) fail_with_saved(errno, directory, "create dirty marker", name_string);
  if (maybe_counted_fault() == -1 || write_all(marker, line, (size_t)length) == -1 ||
      maybe_counted_fault() == -1 || retry_fsync(marker) == -1 ||
      maybe_counted_fault() == -1 || retry_fsync(directory) == -1) {
    int saved = errno;
    preserve_files(marker, -1, directory);
    unix_error(saved, (char *)"durably create dirty marker", caml_copy_string(name_string));
  }
  if (retry_close(marker) == -1) {
    int saved = errno;
    preserve_files(-1, -1, directory);
    unix_error(saved, (char *)"close dirty marker", caml_copy_string(name_string));
  }
  if (close(directory) == -1) uerror("close private state directory", root);
  CAMLreturn(Val_unit);
}

CAMLprim value caml_nixploy_target_lease_write_clean_receipt(value root, value name, value generation) {
  CAMLparam3(root, name, generation);
  const char *name_string = String_val(name);
  char receipt_name[256];
  if (snprintf(receipt_name, sizeof(receipt_name), "%s.clean", name_string) >= (int)sizeof(receipt_name))
    fail_with_saved(EINVAL, -1, "render receipt name", name_string);
  char line[128];
  int length = snprintf(line, sizeof(line), "clean %s\n", String_val(generation));
  if (length <= 0 || (size_t)length >= sizeof(line))
    fail_with_saved(EINVAL, -1, "render clean receipt", name_string);
  int directory = open_private_directory(String_val(root));
  if (directory == -1) uerror("open private state directory", root);
  int receipt = openat(directory, receipt_name,
                       O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (receipt == -1 && errno == EEXIST) {
    /* An existing receipt must be byte-identical to be honored; anything else
       is corruption the startup scan will reject. */
    char existing[64];
    if (!caml_nixploy_target_lease_read_exact(directory, receipt_name, existing, sizeof(existing) - 1) ||
        strncmp(existing, line, (size_t)length) != 0 || existing[length] != '\0')
      fail_with_saved(EEXIST, directory, "conflicting clean receipt", receipt_name);
    close(directory);
    CAMLreturn(Val_unit);
  }
  if (receipt == -1) fail_with_saved(errno, directory, "create clean receipt", receipt_name);
  if (maybe_counted_fault() == -1 || write_all(receipt, line, (size_t)length) == -1 ||
      maybe_counted_fault() == -1 || retry_fsync(receipt) == -1 ||
      maybe_counted_fault() == -1 || retry_fsync(directory) == -1) {
    int saved = errno;
    preserve_files(receipt, -1, directory);
    unix_error(saved, (char *)"durably create clean receipt", caml_copy_string(receipt_name));
  }
  if (retry_close(receipt) == -1) {
    int saved = errno;
    preserve_files(-1, -1, directory);
    unix_error(saved, (char *)"close clean receipt", caml_copy_string(receipt_name));
  }
  if (close(directory) == -1) uerror("close private state directory", root);
  CAMLreturn(Val_unit);
}

CAMLprim value caml_nixploy_target_lease_retire_dirty(value root, value name, value generation) {
  CAMLparam3(root, name, generation);
  const char *name_string = String_val(name);
  char expected[128];
  int length = snprintf(expected, sizeof(expected), "dirty %s\n", String_val(generation));
  if (length <= 0 || (size_t)length >= sizeof(expected))
    fail_with_saved(EINVAL, -1, "render expected marker", name_string);
  int directory = open_private_directory(String_val(root));
  if (directory == -1) uerror("open private state directory", root);
  /* Retire only the exact generation we marked; a mismatched marker is foreign
     or corrupted state and is never removed. */
  char actual[64];
  if (!caml_nixploy_target_lease_read_exact(directory, name_string, actual, sizeof(actual) - 1))
    fail_with_saved(ENOENT, directory, "read dirty marker", name_string);
  if (strncmp(actual, expected, (size_t)length) != 0 || actual[length] != '\0')
    fail_with_saved(EINVAL, directory, "mismatched dirty marker generation", name_string);
  if (maybe_counted_fault() == -1 || retry_unlinkat(directory, name_string) == -1)
    fail_with_saved(errno, directory, "unlink dirty marker", name_string);
  if (maybe_counted_fault() == -1 || retry_fsync(directory) == -1) {
    int saved = errno;
    /* Deliberate: no restoration.  With the receipt already durable, losing
       this fsync can only leave both files (blocked) or clean-only truth. */
    preserve_files(-1, -1, directory);
    unix_error(saved, (char *)"fsync state directory after retiring dirty marker", caml_copy_string(name_string));
  }
  if (close(directory) == -1) uerror("close private state directory", root);
  CAMLreturn(Val_unit);
}

static int random_bytes(unsigned char *bytes, size_t length) {
  size_t offset = 0;
  while (offset < length) {
    ssize_t count = getrandom(bytes + offset, length - offset, 0);
    if (count > 0) offset += (size_t)count;
    else if (count == -1 && errno == EINTR) continue;
    else break;
  }
  if (offset == length) return 0;
  int random_fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (random_fd == -1) return -1;
  while (offset < length) {
    ssize_t count = read(random_fd, bytes + offset, length - offset);
    if (count > 0) offset += (size_t)count;
    else if (count == -1 && errno == EINTR) continue;
    else { if (count == 0) errno = EIO; close(random_fd); return -1; }
  }
  return close(random_fd);
}

CAMLprim value caml_nixploy_target_lease_random_uuid(value unit) {
  CAMLparam1(unit);
  CAMLlocal1(result);
  unsigned char bytes[16];
  static const char hex[] = "0123456789abcdef";
  char uuid[37];
  if (random_bytes(bytes, sizeof(bytes)) == -1) uerror("read cryptographic randomness", Nothing);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  int output = 0;
  for (int index = 0; index < 16; index++) {
    if (output == 8 || output == 13 || output == 18 || output == 23) uuid[output++] = '-';
    uuid[output++] = hex[bytes[index] >> 4];
    uuid[output++] = hex[bytes[index] & 0x0f];
  }
  uuid[36] = '\0';
  result = caml_copy_string(uuid);
  CAMLreturn(result);
}
