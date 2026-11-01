#include "pw.h"
#include <errno.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <signal.h>
#include <sys/resource.h>

static mach_timebase_info_data_t tb;

/* not raw CNTVCT: 1GHz + per-core skew on M4, mach_abs is scaled */
uint64_t pw_tick(void) { return mach_absolute_time(); }

uint64_t pw_ns(uint64_t tk)
{
	if (!tb.denom) mach_timebase_info(&tb);
	return (uint64_t)((unsigned __int128)tk * tb.numer / tb.denom);
}

uint64_t pw_tk(uint64_t ns)
{
	if (!tb.denom) mach_timebase_info(&tb);
	return (uint64_t)((unsigned __int128)ns * tb.denom / tb.numer);
}

/* ri_*time is in mach abs units on arm64, not ns */
int pw_ru_get(pid_t p, pw_ru *o)
{
	struct rusage_info_v6 r;
	if (proc_pid_rusage(p, RUSAGE_INFO_V6, (rusage_info_t *)&r)) return -1;
	o->t = pw_ns(r.ri_user_time + r.ri_system_time);
	o->pt = pw_ns(r.ri_user_ptime + r.ri_system_ptime);
	o->nj = r.ri_energy_nj ? r.ri_energy_nj : r.ri_billed_energy;
	return 0;
}

int pw_pids(pid_t *b, int n)
{
	int c = proc_listallpids(b, n * (int)sizeof *b);
	return c < 0 ? 0 : c;
}

int pw_path(pid_t p, char *b, int n) { return proc_pidpath(p, b, (uint32_t)n) > 0; }

/* == taskpolicy -b: DARWIN_BG -> bg QoS, E-cores only on AS */
int pw_bg(pid_t p, int on) { return setpriority(PRIO_DARWIN_PROCESS, p, on ? PRIO_DARWIN_BG : 0); }

int pw_getnice(pid_t p)
{
	errno = 0;
	int v = getpriority(PRIO_PROCESS, (id_t)p);
	return errno ? 0 : v;
}

int pw_nice(pid_t p, int v) { return setpriority(PRIO_PROCESS, (id_t)p, v); }

int pw_stop(pid_t p, int on) { return kill(p, on ? SIGSTOP : SIGCONT); }
