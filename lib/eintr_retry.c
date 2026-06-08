#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <sys/epoll.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

typedef void (*signal_handler_t)(int);

/* Original libc symbols resolved through RTLD_NEXT for LD_PRELOAD interception */
static int (*real_sigaction_fn)(int, const struct sigaction *, struct sigaction *);
static signal_handler_t (*real_signal_fn)(int, signal_handler_t);
static int (*real_siginterrupt_fn)(int, int);
static ssize_t (*real_read_fn)(int, void *, size_t);
static ssize_t (*real_recv_fn)(int, void *, size_t, int);
static ssize_t (*real_recvfrom_fn)(int, void *, size_t, int, struct sockaddr *, socklen_t *);
static ssize_t (*real_recvmsg_fn)(int, struct msghdr *, int);
static int (*real_socket_fn)(int, int, int);
static int (*real_accept_fn)(int, struct sockaddr *, socklen_t *);
static int (*real_accept4_fn)(int, struct sockaddr *, socklen_t *, int);
static int (*real_fcntl_fn)(int, int, ...);
static int (*real_poll_fn)(struct pollfd *, nfds_t, int);
static int (*real_ppoll_fn)(struct pollfd *, nfds_t, const struct timespec *, const sigset_t *);
static int (*real_select_fn)(int, fd_set *, fd_set *, fd_set *, struct timeval *);
static int (*real_pselect_fn)(int, fd_set *, fd_set *, fd_set *, const struct timespec *, const sigset_t *);
static int (*real_epoll_wait_fn)(int, struct epoll_event *, int, int);
static int (*real_epoll_pwait_fn)(int, struct epoll_event *, int, int, const sigset_t *);
static pid_t (*real_waitpid_fn)(pid_t, int *, int);
static pid_t (*real_wait4_fn)(pid_t, int *, int, struct rusage *);
static int (*real_nanosleep_fn)(const struct timespec *, struct timespec *);

static void load_symbols(void) {
  if (real_read_fn) return;

  /* Resolve all wrapped calls once so hot paths only retry the real libc calls */
  real_sigaction_fn = dlsym(RTLD_NEXT, "sigaction");
  real_signal_fn = dlsym(RTLD_NEXT, "signal");
  real_siginterrupt_fn = dlsym(RTLD_NEXT, "siginterrupt");
  real_read_fn = dlsym(RTLD_NEXT, "read");
  real_recv_fn = dlsym(RTLD_NEXT, "recv");
  real_recvfrom_fn = dlsym(RTLD_NEXT, "recvfrom");
  real_recvmsg_fn = dlsym(RTLD_NEXT, "recvmsg");
  real_socket_fn = dlsym(RTLD_NEXT, "socket");
  real_accept_fn = dlsym(RTLD_NEXT, "accept");
  real_accept4_fn = dlsym(RTLD_NEXT, "accept4");
  real_fcntl_fn = dlsym(RTLD_NEXT, "fcntl");
  real_poll_fn = dlsym(RTLD_NEXT, "poll");
  real_ppoll_fn = dlsym(RTLD_NEXT, "ppoll");
  real_select_fn = dlsym(RTLD_NEXT, "select");
  real_pselect_fn = dlsym(RTLD_NEXT, "pselect");
  real_epoll_wait_fn = dlsym(RTLD_NEXT, "epoll_wait");
  real_epoll_pwait_fn = dlsym(RTLD_NEXT, "epoll_pwait");
  real_waitpid_fn = dlsym(RTLD_NEXT, "waitpid");
  real_wait4_fn = dlsym(RTLD_NEXT, "wait4");
  real_nanosleep_fn = dlsym(RTLD_NEXT, "nanosleep");
}

static void add_sigchld_restart(struct sigaction *action) {
  /* Keep blocking RPC reads from failing when aTrust child processes exit */
  if (action) action->sa_flags |= SA_RESTART;
}

static void set_cloexec(int fd) {
  int flags;

  if (fd < 0 || !real_fcntl_fn) return;

  flags = real_fcntl_fn(fd, F_GETFD);
  if (flags == -1) return;

  /* Avoid leaking listener descriptors into aTrust helper processes */
  real_fcntl_fn(fd, F_SETFD, flags | FD_CLOEXEC);
}

__attribute__((constructor))
static void init_eintr_retry(void) {
  load_symbols();
}

int sigaction(int signum, const struct sigaction *act, struct sigaction *oldact) {
  load_symbols();

  if (signum == SIGCHLD && act) {
    struct sigaction copy = *act;
    add_sigchld_restart(&copy);
    return real_sigaction_fn(signum, &copy, oldact);
  }

  return real_sigaction_fn(signum, act, oldact);
}

signal_handler_t signal(int signum, signal_handler_t handler) {
  load_symbols();

  if (signum == SIGCHLD && handler != SIG_ERR) {
    struct sigaction action;
    struct sigaction old_action;

    /* Match signal(2) callers to sigaction(2) semantics while preserving restart behavior */
    sigemptyset(&action.sa_mask);
    action.sa_handler = handler;
    action.sa_flags = SA_RESTART;

    if (real_sigaction_fn(signum, &action, &old_action) == -1) {
      return SIG_ERR;
    }

    return old_action.sa_handler;
  }

  return real_signal_fn(signum, handler);
}

int siginterrupt(int signum, int flag) {
  load_symbols();

  if (signum == SIGCHLD) flag = 0;
  return real_siginterrupt_fn(signum, flag);
}

ssize_t read(int fd, void *buf, size_t count) {
  ssize_t rc;
  load_symbols();

  do {
    rc = real_read_fn(fd, buf, count);
  } while (rc == -1 && errno == EINTR);

  return rc;
}

ssize_t recv(int sockfd, void *buf, size_t len, int flags) {
  ssize_t rc;
  load_symbols();

  do {
    rc = real_recv_fn(sockfd, buf, len, flags);
  } while (rc == -1 && errno == EINTR);

  return rc;
}

ssize_t recvfrom(int sockfd, void *buf, size_t len, int flags, struct sockaddr *src_addr, socklen_t *addrlen) {
  ssize_t rc;
  load_symbols();

  do {
    rc = real_recvfrom_fn(sockfd, buf, len, flags, src_addr, addrlen);
  } while (rc == -1 && errno == EINTR);

  return rc;
}

ssize_t recvmsg(int sockfd, struct msghdr *msg, int flags) {
  ssize_t rc;
  load_symbols();

  do {
    rc = real_recvmsg_fn(sockfd, msg, flags);
  } while (rc == -1 && errno == EINTR);

  return rc;
}

int socket(int domain, int type, int protocol) {
  int rc;
  load_symbols();

#ifdef SOCK_CLOEXEC
  rc = real_socket_fn(domain, type | SOCK_CLOEXEC, protocol);
  if (rc == -1 && errno == EINVAL) {
    rc = real_socket_fn(domain, type, protocol);
    set_cloexec(rc);
  }
#else
  rc = real_socket_fn(domain, type, protocol);
  set_cloexec(rc);
#endif

  return rc;
}

int accept(int sockfd, struct sockaddr *addr, socklen_t *addrlen) {
  int rc;
  load_symbols();

  do {
    rc = real_accept_fn(sockfd, addr, addrlen);
  } while (rc == -1 && errno == EINTR);

  set_cloexec(rc);
  return rc;
}

int accept4(int sockfd, struct sockaddr *addr, socklen_t *addrlen, int flags) {
  int rc;
  load_symbols();

  do {
    rc = real_accept4_fn(sockfd, addr, addrlen, flags | SOCK_CLOEXEC);
  } while (rc == -1 && errno == EINTR);

  set_cloexec(rc);
  return rc;
}

int poll(struct pollfd *fds, nfds_t nfds, int timeout) {
  int rc;
  load_symbols();

  do {
    rc = real_poll_fn(fds, nfds, timeout);
  } while (rc == -1 && errno == EINTR);

  return rc;
}

int ppoll(struct pollfd *fds, nfds_t nfds, const struct timespec *timeout_ts, const sigset_t *sigmask) {
  int rc;
  load_symbols();

  do {
    rc = real_ppoll_fn(fds, nfds, timeout_ts, sigmask);
  } while (rc == -1 && errno == EINTR);

  return rc;
}

int select(int nfds, fd_set *readfds, fd_set *writefds, fd_set *exceptfds, struct timeval *timeout) {
  int rc;
  load_symbols();

  do {
    struct timeval timeout_copy;
    struct timeval *timeout_ptr = timeout;

    /* Retry with the original timeout value because select mutates the timeval argument */
    if (timeout) {
      timeout_copy = *timeout;
      timeout_ptr = &timeout_copy;
    }

    rc = real_select_fn(nfds, readfds, writefds, exceptfds, timeout_ptr);
  } while (rc == -1 && errno == EINTR);

  return rc;
}

int pselect(int nfds, fd_set *readfds, fd_set *writefds, fd_set *exceptfds, const struct timespec *timeout, const sigset_t *sigmask) {
  int rc;
  load_symbols();

  do {
    rc = real_pselect_fn(nfds, readfds, writefds, exceptfds, timeout, sigmask);
  } while (rc == -1 && errno == EINTR);

  return rc;
}

int epoll_wait(int epfd, struct epoll_event *events, int maxevents, int timeout) {
  int rc;
  load_symbols();

  do {
    rc = real_epoll_wait_fn(epfd, events, maxevents, timeout);
  } while (rc == -1 && errno == EINTR);

  return rc;
}

int epoll_pwait(int epfd, struct epoll_event *events, int maxevents, int timeout, const sigset_t *sigmask) {
  int rc;
  load_symbols();

  do {
    rc = real_epoll_pwait_fn(epfd, events, maxevents, timeout, sigmask);
  } while (rc == -1 && errno == EINTR);

  return rc;
}

pid_t waitpid(pid_t pid, int *wstatus, int options) {
  pid_t rc;
  load_symbols();

  do {
    rc = real_waitpid_fn(pid, wstatus, options);
  } while (rc == -1 && errno == EINTR);

  return rc;
}

pid_t wait4(pid_t pid, int *wstatus, int options, struct rusage *rusage) {
  pid_t rc;
  load_symbols();

  do {
    rc = real_wait4_fn(pid, wstatus, options, rusage);
  } while (rc == -1 && errno == EINTR);

  return rc;
}

int nanosleep(const struct timespec *req, struct timespec *rem) {
  int rc;
  struct timespec remaining;
  const struct timespec *current = req;
  load_symbols();

  /* Continue sleeping with the kernel-reported remaining duration after EINTR */
  do {
    rc = real_nanosleep_fn(current, &remaining);
    current = &remaining;
  } while (rc == -1 && errno == EINTR);

  if (rem && rc == -1) *rem = remaining;
  return rc;
}
