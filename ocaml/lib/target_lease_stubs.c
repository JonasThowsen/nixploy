#define _GNU_SOURCE
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/unixsupport.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/select.h>
#include <signal.h>
#include <unistd.h>

static int retry_fsync(int fd) {
  int result;
  do result = fsync(fd); while (result == -1 && errno == EINTR);
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

/* Once a marker has been created we never unlink it on an error.  Best-effort
   sync makes the conservative state survive as many failure modes as possible. */
static void preserve_marker(int marker, int directory) {
  if (marker >= 0) {
    (void)retry_fsync(marker);
    (void)close(marker);
  }
  if (directory >= 0) (void)retry_fsync(directory);
}

CAMLprim value caml_nixploy_target_lease_mark_dirty(value root, value name) {
  CAMLparam2(root, name);
  int directory = open_private_directory(String_val(root));
  if (directory == -1) uerror("open private state directory", root);
  int marker = openat(directory, String_val(name),
                      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                      0600);
  if (marker == -1) {
    int saved = errno; close(directory); errno = saved;
    uerror("create target-lease marker", name);
  }
  const char contents[] = "dirty\n";
  if (write_all(marker, contents, sizeof(contents) - 1) == -1 ||
      retry_fsync(marker) == -1) {
    int saved = errno;
    preserve_marker(marker, directory);
    close(directory);
    errno = saved;
    uerror("durably create target-lease marker", name);
  }
  if (close(marker) == -1) {
    int saved = errno;
    marker = -1;
    preserve_marker(marker, directory);
    close(directory);
    errno = saved;
    uerror("close target-lease marker", name);
  }
  marker = -1;
  if (retry_fsync(directory) == -1) {
    int saved = errno;
    preserve_marker(marker, directory);
    close(directory);
    errno = saved;
    uerror("fsync target-lease state directory", root);
  }
  if (close(directory) == -1) uerror("close target-lease state directory", root);
  CAMLreturn(Val_unit);
}

/* If unlink reached the directory but its fsync did not, restore the dirty
   marker and sync it before reporting failure.  The caller treats every clear
   failure as fatal, so it cannot serve an uncertain lease state. */
CAMLprim value caml_nixploy_target_lease_clear_dirty(value root, value name) {
  CAMLparam2(root, name);
  int directory = open_private_directory(String_val(root));
  if (directory == -1) uerror("open private state directory", root);
  if (retry_unlinkat(directory, String_val(name)) == -1) {
    int saved = errno; close(directory); errno = saved;
    uerror("unlink target-lease marker", name);
  }
  if (retry_fsync(directory) == -1) {
    int saved = errno;
    int marker = openat(directory, String_val(name),
                        O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC,
                        0600);
    if (marker >= 0) {
      const char contents[] = "dirty\n";
      (void)write_all(marker, contents, sizeof(contents) - 1);
      (void)retry_fsync(marker);
      (void)close(marker);
      (void)retry_fsync(directory);
    }
    close(directory);
    errno = saved;
    uerror("fsync target-lease state directory after unlink", root);
  }
  if (close(directory) == -1) uerror("close target-lease state directory", root);
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
