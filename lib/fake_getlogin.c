#define _GNU_SOURCE

#include <errno.h>
#include <pwd.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *fallback_login_name(void) {
  const char *name;

  /* aTrust checks the login name when spawning plugins under Docker */
  name = getenv("FAKE_LOGIN");
  if (name && *name) return name;

  name = getenv("USER");
  if (name && *name) return name;

  name = getenv("LOGNAME");
  if (name && *name) return name;

  return "sangfor";
}

char *getlogin(void) {
  return (char *)fallback_login_name();
}

int getlogin_r(char *buf, size_t bufsize) {
  const char *name;
  size_t len;

  if (bufsize == 0) {
    errno = ERANGE;
    return ERANGE;
  }

  name = fallback_login_name();
  len = strlen(name);
  if (len + 1 > bufsize) {
    errno = ERANGE;
    return ERANGE;
  }

  memcpy(buf, name, len + 1);
  return 0;
}

char *cuserid(char *s) {
  const char *name;

  name = fallback_login_name();
  if (!s) return (char *)name;

  snprintf(s, L_cuserid, "%s", name);
  return s;
}
