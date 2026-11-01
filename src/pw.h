#pragma once
#include <stdint.h>
#include <sys/types.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct { uint64_t t, pt, nj; } pw_ru; /* cpu ns, pcore ns, nrg nJ */

uint64_t pw_tick(void);
uint64_t pw_ns(uint64_t tk);
uint64_t pw_tk(uint64_t ns);
int pw_ru_get(pid_t p, pw_ru *o);
int pw_pids(pid_t *b, int n);
int pw_path(pid_t p, char *b, int n);
int pw_bg(pid_t p, int on);
int pw_getnice(pid_t p);
int pw_nice(pid_t p, int v);
int pw_stop(pid_t p, int on);

#ifdef __cplusplus
}
#endif
