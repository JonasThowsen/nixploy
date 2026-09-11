#include <caml/mlvalues.h>
#include <caml/unixsupport.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>

CAMLprim value nixploy_terminal_foreground_group(value fd) {
  pid_t group = tcgetpgrp(Int_val(fd));
  if (group == -1) uerror("tcgetpgrp", Nothing);
  return Val_int(group);
}

/* Block SIGTTOU only in the calling thread, not process-wide. The parent must
   reclaim the terminal while its child's group is still the foreground group. */
CAMLprim value nixploy_terminal_set_foreground_group(value fd, value group) {
  sigset_t blocked, previous;
  sigemptyset(&blocked);
  sigaddset(&blocked, SIGTTOU);
  int error = pthread_sigmask(SIG_BLOCK, &blocked, &previous);
  if (error) { errno = error; uerror("pthread_sigmask", Nothing); }
  int result;
  do result = tcsetpgrp(Int_val(fd), Int_val(group));
  while (result == -1 && errno == EINTR);
  int saved_errno = errno;
  error = pthread_sigmask(SIG_SETMASK, &previous, NULL);
  if (result == -1) { errno = saved_errno; uerror("tcsetpgrp", Nothing); }
  if (error) { errno = error; uerror("pthread_sigmask", Nothing); }
  return Val_unit;
}
