# powerwarden

powerwarden is a small macOS daemon that limits how much CPU time and energy
individual apps are allowed to use. You describe each app and its budget in a
config file, and powerwarden samples the matching processes at a fixed
interval and throttles an app whenever its combined usage goes over the
budget. The main process and all of its helpers are counted as one group, so
a rule for `Slack.app` also covers every `Slack Helper` process that lives
inside the bundle.

## Requirements

You need macOS 13 or later on either Apple Silicon or Intel. Building from
source also requires the Xcode Command Line Tools, which you can install with
`xcode-select --install`.

## Installing

Prebuilt universal binaries are attached to each GitHub release:

```sh
curl -LO https://github.com/tryhard-26/powerwarden/releases/download/v0.1.0/powerwarden-v0.1.0-macos-universal.tar.gz
tar xzf powerwarden-v0.1.0-macos-universal.tar.gz
cd powerwarden-v0.1.0-macos-universal
./powerwarden -V
```

To build from source, clone the repository and run `make`, which writes the
binary to `build/powerwarden`. Running `make check` afterwards starts a busy
loop, caps it at 25% with a `stop` rule and verifies that the process is
resumed when powerwarden exits normally and after it has been killed and
restarted.

```sh
git clone https://github.com/tryhard-26/powerwarden
cd powerwarden
make
make check
```

## Getting started

Put a couple of rules in a file, for example `rules.conf`:

```
# match            cpu%  watts  action
"Slack.app"         30    1.5    stop
"Discord.app"       40    -      bg
```

and run powerwarden in the foreground with `-v` so that it prints the state
of every rule after each sample:

```sh
build/powerwarden -v -c rules.conf
```

Each line of output shows the rule, the number of matched processes, CPU
usage where 100% equals one full core, the part of that usage that ran on
performance cores, power in watts, the load relative to the budget (anything
above 1 means the app is over), the action currently applied and, for `stop`
rules, the duty cycle. When you stop powerwarden with Ctrl-C it resumes and
resets every process it was throttling before exiting.

## Running as a daemon

`sudo make install` copies the binary to `/usr/local/bin`, installs the
example config as `/usr/local/etc/powerwarden.conf` unless a config already
exists there, and adds a launchd job that you can load with:

```sh
sudo launchctl bootstrap system /Library/LaunchDaemons/org.tryhard.powerwarden.plist
```

The daemon logs to `/var/log/powerwarden.log` and can be removed again with
`sudo make uninstall`. When powerwarden runs as a normal user instead of
root, it can only throttle processes owned by that same user.

## Configuration

The config file holds one rule per line in the form
`<match> <cpu%> <watts> <action>`, and anything after a `#` is ignored. The
match string is compared against the full executable path of every process,
and it needs quotes if it contains spaces, as in `"Microsoft Teams.app"`.
The CPU budget is summed over the whole group and uses the same scale as
Activity Monitor, where 100 means one fully busy core, while the power budget
is in watts and is derived from the kernel's per-process energy counter.
Either budget can be replaced with `-` to leave it unlimited, but a rule must
set at least one of them. When the system thermal state reaches *fair* or
worse, every budget is multiplied by the value given with `-k`, which
defaults to 0.5, so apps are held back harder before the fans spin up.

## Actions

The `stop` action pauses and resumes the group with SIGSTOP and SIGCONT once
per quantum, which is 100 ms by default, and adjusts the fraction of each
quantum the group is allowed to run so that its usage settles at the budget.
It is the only action that enforces a hard limit, but because a paused UI
process cannot respond to input it works best for helper and renderer
processes rather than an app's main window.

The `bg` action moves the group into the Darwin background band, which is
the same thing `taskpolicy -b` does. On Apple Silicon this keeps the
processes on the efficiency cores and also throttles their disk I/O, which
does not cap CPU percentage but usually lowers power draw considerably.

The `nice` action sets the group's nice value to 20. Only root can lower a
nice value again, so this action should only be used when powerwarden runs
as root.

Both `bg` and `nice` are switched on as soon as a group goes over budget and
are switched off once it has stayed below half of the budget for the number
of samples given with `-H`, which defaults to 10.

## Options

```
powerwarden [-nvV] [-c conf] [-i ms] [-q ms] [-k scale] [-H n]

-c  rules file (default /usr/local/etc/powerwarden.conf)
-i  sample interval in ms (default 1000)
-q  stop quantum in ms (default 100)
-k  budget multiplier at thermal state fair or worse (default 0.5)
-H  samples under half budget before bg/nice is released (default 10)
-n  dry run that measures and prints but never throttles
-v  print per-rule stats after every sample
-V  print the version
```

## Source layout

The system-facing code is in `src/sys.c`, which lists processes, reads
their usage through `proc_pid_rusage(RUSAGE_INFO_V6)` and wraps the
`setpriority` and signal calls used for throttling. `src/main.mm` is written
in Objective-C++ and contains the rule parser, the sampling loop, the
duty-cycle controller and the thermal state check through `NSProcessInfo`.
The end-to-end test lives in `test/check.sh`, and `etc/` holds the example
config and the launchd plist.

## Contributing

Bug reports and pull requests are welcome. When reporting a problem, please
include your macOS version, your chip and the rule that misbehaved, and
before sending a change, run `make check` and try to keep the patch small and
in the style of the surrounding code.

## License

powerwarden is released under the MIT license, see [LICENSE](LICENSE).
