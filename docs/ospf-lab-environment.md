# Lab Environment

Ubuntu VM running FRRouting 10.6.1 (upgraded from the distro default
8.4.4 specifically to get RFC 5709 HMAC-SHA-256 support for OSPF, which
8.4.4 doesn't have). Four routers simulated as Linux network namespaces
(R1-R4) connected via veth pairs, each running independent zebra/ospfd
instances via FRR's `-N <pathspace>` isolation. A fifth namespace
(ATTACKER) was added for Phase 7.

Topology:
- R1 (1.1.1.1) -- R2 (2.2.2.2): 10.0.12.0/30
- R2 -- R3 (3.3.3.3): 10.0.23.0/30
- R2 -- R4 (4.4.4.4): 10.0.24.0/30
- R2 -- ATTACKER (9.9.9.9): 10.0.99.0/30 (Phase 7 only)

All routers run OSPF area 0. R2 is the only multi-homed router and the
transit point for R1's reachability to R3 and R4.

Environment is rebuilt every session via `scripts/start-lab.sh`.

## Config persists, environment doesn't

Two categories of state behave differently across a VM reboot:

- **Persists on disk:** installed packages, and everything under
  `/etc/frr/<router>/` — saved zebra.conf / ospfd.conf, since
  `write memory` commits them to disk.
- **Wiped on reboot:** the namespaces themselves, veth links, IP
  addressing, `ip_forward`, and the running zebra/ospfd processes.
  `/var/run/frr/<router>` is also wiped despite looking like a normal
  path — `/var/run` is tmpfs (memory-backed).

`start-lab.sh` rebuilds the environment every session; it doesn't need
to reconfigure OSPF, since the saved configs load automatically once
zebra/ospfd start against them — provided they're launched correctly
(see below).

## Issue: saved config not loading on daemon restart

**Symptom:** fresh zebra/ospfd launch, `show ip ospf neighbor` returns
"OSPF is not enabled in vrf default" despite a valid, saved
`router ospf` block already in `/etc/frr/<router>/ospfd.conf`.

**Cause:** `-N <pathspace>` alone doesn't reliably auto-load the config
from its default expected path on this FRR build.

**Fix:** launch every daemon with an explicit
`-f /etc/frr/<router>/<daemon>.conf` instead of relying on `-N`'s
implicit path lookup.

**Note:** this fix was applied live via terminal the first time it came
up, but didn't actually get saved into `start-lab.sh` itself — the
script silently reverted to the broken version on the next VM restart,
days later, and had to be re-diagnosed and fixed a second time, this
time verified with `grep -n "\-f /etc/frr"` against the actual script
file before trusting it. Lesson: a live terminal fix and a saved script
fix are two different things: always verify the file, not just the
terminal output.

## Issue: stale PID lock blocks daemon restart

**Symptom:** relaunching ospfd with the `-f` fix above sometimes returns
`Could not lock pid_file ... (Resource temporarily unavailable)`.

**Cause:** a previous (often broken, pre-fix) daemon instance is still
running and holding the PID lock — two ospfd processes can't hold the
same lock for the same namespace.

**Fix:** `pkill -f "ospfd -d -N <router>"`, confirm with `pgrep` that
it's gone, then relaunch. Only an issue mid-session when a stale daemon
is still alive — a genuine cold reboot wipes `/var/run` (tmpfs), so no
stale lock can exist there.

## Issue: OSPF adjacency stalls at 2-Way on virtual point-to-point links

**Symptom:** router-to-router adjacencies with exactly two possible
participants (every link in this topology) stuck at `2-Way/DROther`,
never reaching Full, despite confirmed connectivity.

**Cause:** `show ip ospf interface <if>` shows `Network Type BROADCAST`
by default. OSPF requires DR/BDR election before non-DR/BDR neighbors
reach Full on broadcast-type interfaces (RFC 2328 S10.4) — an election
that serves no purpose on a link that can only ever have two routers,
and can stall on virtual interfaces.

**Fix:** `ip ospf network point-to-point` on both ends of every
router-to-router interface, including newly-added ones (this had to be
reapplied when the ATTACKER link was built in Phase 7).

## Issue: backgrounded sudo commands stall silently

**Symptom:** a `sudo`-prefixed command backgrounded with `&` shows
`[1]+ Stopped` instead of running, and anything it was supposed to
produce never gets created.

**Cause:** `sudo` needs to prompt for a password interactively, which
requires reading from the terminal. A backgrounded process can't do
that — the shell suspends it (SIGTTIN) rather than letting it hang.
Everything scheduled to run after it still executes on time, giving the
illusion the sequence worked when the real work never started.

**Fix:** run `sudo -v` once before backgrounding anything that needs
sudo, to cache credentials for a few minutes.

## Phase 5/6 measurement notes

CPU sampling (`pidstat`) and convergence timing both showed meaningful
trial-to-trial variance — in convergence timing's case, larger than the
difference being measured. Both are reported as inconclusive-but-honest
findings in `analysis.md` rather than forced into a clean narrative;
see that file for the actual numbers and reasoning.

## Security note

Key strings used throughout (`SharedSecret123`, `LabSecret2026`) are
illustrative lab placeholders, not production credentials.
