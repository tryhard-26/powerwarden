#import <Foundation/Foundation.h>
#include "pw.h"
#include <algorithm>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <iomanip>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <unordered_map>
#include <vector>

#ifndef PW_VER
#define PW_VER "dev"
#endif

enum Act { BG, NICE, STOP };

struct Pr { pw_ru last; int nice0; bool seen; };

struct Rule {
	std::string m;
	double cpu = 0, w = 0;
	Act a = STOP;
	std::unordered_map<pid_t, Pr> ps;
	bool on = false;
	int calm = 0;
	double duty = 1, ucpu = 0, up = 0, uw = 0;
};

static std::vector<Rule> R;
static volatile sig_atomic_t quit;
static int dry, verb, hold = 10;
static double kth = 0.5;

static int num(const std::string &s, double &v)
{
	if (s == "-") return v = 0, 1;
	char *e;
	v = strtod(s.c_str(), &e);
	return !*e && v > 0;
}

static int load(const char *f)
{
	struct stat st;
	int fd = open(f, O_RDONLY);
	if (fd < 0 || fstat(fd, &st)) { fprintf(stderr, "pw: can't open %s\n", f); return -1; }
	/* as root, rules a user can edit == user can SIGSTOP anything */
	if (!geteuid() && (st.st_uid || st.st_mode & 022)) {
		fprintf(stderr, "pw: %s must be root-owned and not group/world-writable\n", f);
		close(fd);
		return -1;
	}
	std::string buf, l;
	char b[4096];
	for (ssize_t k; (k = read(fd, b, sizeof b)) > 0;) buf.append(b, (size_t)k);
	close(fd);
	std::istringstream in(buf);
	for (int n = 1; std::getline(in, l); n++) {
		if (auto h = l.find('#'); h != std::string::npos) l.resize(h);
		std::istringstream s(l);
		Rule r;
		std::string c, w, a, x;
		if (!(s >> std::quoted(r.m))) continue;
		if (!(s >> c >> w >> a) || s >> x || r.m.empty()) goto bad;
		if (!num(c, r.cpu) || !num(w, r.w)) goto bad;
		if (a == "bg") r.a = BG;
		else if (a == "nice") r.a = NICE;
		else if (a == "stop") r.a = STOP;
		else goto bad;
		if (r.cpu <= 0 && r.w <= 0) goto bad;
		R.push_back(std::move(r));
		continue;
	bad:
		fprintf(stderr, "pw: %s:%d: bad rule\n", f, n);
		return -1;
	}
	return R.empty() ? -1 : 0;
}

static void apply(Rule &r, pid_t p, Pr &x, bool on)
{
	if (dry) return;
	if (r.a == BG) pw_bg(p, on);
	else if (r.a == NICE) pw_nice(p, on ? 20 : x.nice0);
	else if (!on) pw_stop(p, 0);
}

static double dd(uint64_t a, uint64_t b) { return a > b ? (double)(a - b) : 0; }

static void sample(double dt)
{
	static pid_t pb[8192];
	char path[4096];
	int n = pw_pids(pb, 8192);
	pid_t me = getpid();
	for (auto &r : R) {
		for (auto &kv : r.ps) kv.second.seen = false;
		r.ucpu = r.up = r.uw = 0;
	}
	for (int i = 0; i < n; i++) {
		pid_t p = pb[i];
		if (p <= 1 || p == me || !pw_path(p, path, sizeof path)) continue;
		for (auto &r : R) {
			if (!strstr(path, r.m.c_str())) continue;
			pw_ru u;
			if (pw_ru_get(p, &u)) break;
			auto it = r.ps.find(p);
			if (it != r.ps.end() && it->second.last.st != u.st) {
				r.ps.erase(it); /* pid reused */
				it = r.ps.end();
			}
			if (it == r.ps.end()) {
				Pr x{u, pw_getnice(p), true};
				if (r.a == STOP && !dry) pw_stop(p, 0); /* undo stale SIGSTOP from a killed run */
				if (r.on) apply(r, p, x, true);
				r.ps.emplace(p, x);
				break;
			}
			Pr &x = it->second;
			x.seen = true;
			r.ucpu += dd(u.t, x.last.t) / 1e9;
			r.up += dd(u.pt, x.last.pt) / 1e9;
			r.uw += dd(u.nj, x.last.nj) / 1e9;
			x.last = u;
			break;
		}
	}
	double k;
	@autoreleasepool {
		k = [NSProcessInfo processInfo].thermalState >= NSProcessInfoThermalStateFair ? kth : 1;
	}
	for (auto &r : R) {
		std::erase_if(r.ps, [](auto &kv) { return !kv.second.seen; });
		r.ucpu = r.ucpu / dt * 100;
		r.up = r.up / dt * 100;
		r.uw /= dt;
		double q = 0;
		if (r.cpu > 0) q = std::max(q, r.ucpu / (r.cpu * k));
		if (r.w > 0) q = std::max(q, r.uw / (r.w * k));
		if (r.a == STOP) {
			/* mult duty ctl toward q=1: full step down (hard cap), half step up (no flap on bursts) */
			double d = q > 0 ? r.duty / q : r.duty * 2;
			r.duty = std::clamp(q > 1 ? d : 0.5 * (r.duty + d), 0.02, 1.0);
			bool on = r.duty < 0.999;
			if (r.on && !on)
				for (auto &kv : r.ps) apply(r, kv.first, kv.second, false);
			r.on = on;
		} else if (!r.on && q > 1) {
			r.on = true, r.calm = 0;
			for (auto &kv : r.ps) apply(r, kv.first, kv.second, true);
		} else if (r.on) {
			/* ponytail: fixed hysteresis, may cycle on bursty apps; add PI ctl if it flaps */
			r.calm = q < 0.5 ? r.calm + 1 : 0;
			if (r.calm >= hold) {
				r.on = false;
				for (auto &kv : r.ps) apply(r, kv.first, kv.second, false);
			}
		}
		if (verb)
			fprintf(stderr, "%-24s n=%-3zu cpu %6.1f%% p %6.1f%% %6.2fW q %.2f %s%s\n",
				r.m.c_str(), r.ps.size(), r.ucpu, r.up, r.uw, q,
				r.on ? (r.a == BG ? "bg" : r.a == NICE ? "nice" : "stop") : "-",
				r.a == STOP && r.on ? (" d=" + std::to_string(r.duty).substr(0, 4)).c_str() : "");
	}
}

static void sleep_to(uint64_t t)
{
	uint64_t now = pw_tick();
	if (now >= t || quit) return;
	uint64_t ns = pw_ns(t - now);
	struct timespec ts = {(time_t)(ns / 1000000000), (long)(ns % 1000000000)};
	nanosleep(&ts, 0);
}

/* one quantum: SIGCONT all, SIGSTOP each grp at duty*q
 * ponytail: pid identity checked once per sample, a pid reused inside that window gets signalled;
 * recheck ri_proc_start_abstime per signal if that matters */
static void quantum(uint64_t qtk)
{
	std::vector<Rule *> s;
	for (auto &r : R)
		if (r.a == STOP && r.on && !dry) s.push_back(&r);
	uint64_t t0 = pw_tick();
	std::sort(s.begin(), s.end(), [](Rule *a, Rule *b) { return a->duty < b->duty; });
	for (auto *r : s)
		for (auto &kv : r->ps) pw_stop(kv.first, 0);
	for (auto *r : s) {
		sleep_to(t0 + (uint64_t)(r->duty * qtk));
		if (quit) return;
		for (auto &kv : r->ps) pw_stop(kv.first, 1);
	}
	sleep_to(t0 + qtk);
}

static void restore(void)
{
	if (dry) return;
	for (auto &r : R)
		for (auto &kv : r.ps) {
			if (r.a == STOP) pw_stop(kv.first, 0);
			if (r.on) apply(r, kv.first, kv.second, false);
		}
}

static void onsig(int) { quit = 1; }

static void usage(void)
{
	fprintf(stderr,
		"usage: powerwarden [-nvV] [-c conf] [-i ms] [-q ms] [-k scale] [-H n]\n"
		"  -c  rules file (default /usr/local/etc/powerwarden.conf)\n"
		"  -i  sample interval ms (1000)\n"
		"  -q  stop-duty quantum ms (100)\n"
		"  -k  budget scale when thermal >= fair (0.5)\n"
		"  -H  calm samples before bg/nice release (10)\n"
		"  -n  dry run, measure only\n"
		"  -v  print per-rule stats each sample\n"
		"  -V  print version\n");
	exit(2);
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		const char *cf = "/usr/local/etc/powerwarden.conf";
		int ims = 1000, qms = 100, c;
		while ((c = getopt(argc, argv, "c:i:q:k:H:nvV")) != -1) switch (c) {
			case 'c': cf = optarg; break;
			case 'i': ims = atoi(optarg); break;
			case 'q': qms = atoi(optarg); break;
			case 'k': kth = atof(optarg); break;
			case 'H': hold = atoi(optarg); break;
			case 'n': dry = 1; break;
			case 'v': verb = 1; break;
			case 'V': puts(PW_VER); return 0;
			default: usage();
		}
		if (ims < 10 || qms < 5 || qms > ims || kth <= 0 || hold < 1 || load(cf)) usage();
		for (auto &r : R)
			if (r.a == NICE && geteuid())
				fprintf(stderr, "pw: warn: '%s' nice needs root to restore\n", r.m.c_str());

		struct sigaction sa = {};
		sa.sa_handler = onsig;
		sigaction(SIGINT, &sa, 0);
		sigaction(SIGTERM, &sa, 0);
		sigaction(SIGHUP, &sa, 0);

		uint64_t qtk = pw_tk((uint64_t)qms * 1000000), itk = pw_tk((uint64_t)ims * 1000000);
		int nq = ims / qms;
		uint64_t t = pw_tick();
		sample(1);
		while (!quit) {
			bool act = !dry && std::any_of(R.begin(), R.end(), [](Rule &r) { return r.a == STOP && r.on; });
			if (act)
				for (int i = 0; i < nq && !quit; i++) quantum(qtk);
			else
				sleep_to(t + itk); /* nothing to duty-cycle: 1 wakeup/interval, not 1/quantum */
			if (quit) break;
			uint64_t now = pw_tick();
			sample(pw_ns(now - t) / 1e9);
			t = now;
		}
		restore();
	}
	return 0;
}
