#define _GNU_SOURCE
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/unixsupport.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

CAMLprim value caml_nixploy_target_lease_peer_uid(value fd_value) {
  CAMLparam1(fd_value);
  struct ucred credential;
  socklen_t size = sizeof(credential);
  int fd = Int_val(fd_value);
  if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credential, &size) == -1)
    uerror("getsockopt(SO_PEERCRED)", Nothing);
  CAMLreturn(Val_int(credential.uid));
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
  if (write(marker, contents, sizeof(contents) - 1) != sizeof(contents) - 1 || fsync(marker) == -1) {
    int saved = errno; close(marker); close(directory); errno = saved;
    uerror("fsync target-lease marker", name);
  }
  if (close(marker) == -1 || fsync(directory) == -1) {
    int saved = errno; close(directory); errno = saved;
    uerror("fsync target-lease state directory", root);
  }
  close(directory);
  CAMLreturn(Val_unit);
}

CAMLprim value caml_nixploy_target_lease_clear_dirty(value root, value name) {
  CAMLparam2(root, name);
  int directory = open_private_directory(String_val(root));
  if (directory == -1) uerror("open private state directory", root);
  if (unlinkat(directory, String_val(name), 0) == -1 || fsync(directory) == -1) {
    int saved = errno; close(directory); errno = saved;
    uerror("clear target-lease marker", name);
  }
  close(directory);
  CAMLreturn(Val_unit);
}
