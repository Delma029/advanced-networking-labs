# Lab Environment

Ubuntu VM running FRRouting 10.6.1. Four routers simulated as Linux network
namespaces (R1-R4), connected via veth pairs, each running independent
zebra/ospfd instances via FRR's `-N <pathspace>` isolation. Environment is
rebuilt from `scripts/start-lab.sh` at the start of every session (see
"Environment persistence" below for why this is necessary).

Topology:
- R1 (1.1.1.1) -- R2 (2.2.2.2): 10.0.12.0/30
- R2 -- R3 (3.3.3.3): 10.0.23.0/30
- R2 -- R4 (4.4.4.4): 10.0.24.0/30

All four routers run OSPF area 0. R2 is the only multi-homed router,
making it the transit point for R1<->R3 and R1<->R4 reachability.

## Environment persistence: config vs. runtime state

Two categories of state behave differently across a VM reboot:

**Persists on disk:** installed packages, and everything under
`/etc/frr/<router>/` — the saved `zebra.conf` / `ospfd.conf` files, since
`write memory` commits them to disk.

**Lives only in kernel memory, wiped on reboot:** the network namespaces
themselves, veth links, assigned IP addresses, `ip_forward`, and the
running zebra/ospfd processes. `/var/run/frr/<router>` is also affected
despite looking like a normal path — `/var/run` is tmpfs (memory-backed).

Practical result: `start-lab.sh` rebuilds the *environment* every session
(namespaces, links, addressing, forwarding, daemon launch) — it does not
need to reconfigure OSPF, since the saved configs are picked up
automatically the moment zebra/ospfd start against them.

## Operational issue 1: saved config not loading on daemon restart

**Symptom:** after a fresh zebra/ospfd launch, `show ip ospf neighbor`
returned "OSPF is not enabled in vrf default" despite a complete, valid
`router ospf` block already saved in `/etc/frr/<router>/ospfd.conf`.

**Diagnosis:** `-N <pathspace>` alone did not reliably auto-load the config
from its default expected path on this FRR build.

**Fix:** launch every daemon with an explicit `-f /etc/frr/<router>/<daemon>.conf`
rather than relying on `-N`'s implicit path lookup. Applied to both the
zebra and ospfd launch loops in `start-lab.sh`.

## Operational issue 2: stale PID lock blocks daemon restart

**Symptom:** after adding `-f` above and relaunching ospfd, got: `Could not
lock pid_file ... (Resource temporarily unavailable)`.

**Diagnosis:** the previous (broken, pre-`-f`) ospfd instance was still
running and holding the PID lock in `/var/run/frr/<router>/ospfd.pid` —
two ospfd processes can't hold the same lock for the same namespace.

**Fix:** `pkill -f "ospfd -d -N <router>"` to kill the stale instance,
confirm with `pgrep` that it's gone, then relaunch.

**Note:** this only occurs mid-session, when a broken daemon is still
alive. On a genuine cold VM reboot, `/var/run` (tmpfs) is wiped clean, so
no stale process or lock file can exist — `start-lab.sh` does not need a
`pkill` step for a real reboot, only for live troubleshooting.

## Operational issue 3: OSPF adjacency stalls at 2-Way on virtual point-to-point links

**Symptom:** R2-R3 and R2-R4 adjacencies stuck at `2-Way/DROther`, never
reaching Full, despite confirmed IP connectivity and zero packet loss.

**Diagnosis:** `show ip ospf interface <if>` showed `Network Type
BROADCAST`. OSPF requires DR/BDR election to complete before non-DR/BDR
neighbors reach Full on broadcast-type interfaces (RFC 2328 S10.4). These
veth links only ever have two possible participants, so the election
serves no purpose and can stall on virtual interfaces.

**Fix:** `ip ospf network point-to-point` on both ends of every
router-to-router interface, skipping DR/BDR election entirely.

**Note:** R1-R2 happened not to exhibit the stall, but the same fix was
applied there too for topology-wide consistency — a real dedicated
point-to-point research link wouldn't run DR/BDR election either.

## Phase 1: No-authentication baseline

R1's routing table confirms full end-to-end reachability learned purely
via OSPF: `3.3.3.3/32` and `4.4.4.4/32` both reachable via `10.0.12.2` at
cost 20, despite R1 having no direct link to R3 or R4. This is the
no-auth control group that Phase 2 (MD5) and Phase 3 (SHA-256) are
compared against. Configs: `configs/noauth/`.

## Phase 2: MD5 authentication (R1-R2)

Configured `ip ospf message-digest-key 1 md5 <key>` on veth-r1-r2, with
`ip ospf authentication message-digest` enabling it on the interface.

**Mismatch behavior:** applying MD5 to R1 alone (R2 unauthenticated)
caused the R1-R2 adjacency to drop from the neighbor table entirely — a
hard failure, not a degraded state.

**Note:** MD5 was demonstrated as a deliberate stepping-stone to
SHA-256, not deployed topology-wide — R2-R3 and R2-R4 went straight from
no-auth to SHA-256 (Phase 3). Configs: `configs/md5/` (all four routers).

## Phase 3: HMAC-SHA-256 authentication (topology-wide)

Replaced MD5 with a key chain object (`key chain OSPF-SHA`, `key 1`,
`cryptographic-algorithm hmac-sha-256`), referenced per-interface via
`ip ospf authentication key-chain OSPF-SHA` — structurally different from
MD5's interface-local `message-digest-key`.

**Mismatch behavior (R1-R2):** applying SHA-256 to R1 alone caused the
same hard failure as MD5 — R2 vanished from R1's neighbor table entirely.
Recovered to `Full/-` once R2 was configured with an identical key chain
(same name, key ID, key-string, algorithm).

**Extended topology-wide:** R2-R3 and R2-R4 were then configured directly
with SHA-256 (no MD5 intermediate step), using the same `OSPF-SHA` key
chain already defined on R2.

**Observation — authentication is enforced prospectively, not
retroactively:** after extending SHA-256 to R2-R3/R2-R4, their up-timers
were unchanged (6h14m+), while R1-R2 (deliberately broken and rebuilt)
showed a fresh, short uptime. FRR does not tear down an already-Full
adjacency when authentication is newly applied — it only begins requiring
auth on the next hello exchange onward. Confirmed via saved config
(`configs/sha256/`), not just live session state.

**Result:** full topology authenticated. `show ip ospf neighbor` on R1 and
R2 confirms every neighbor at `Full/-`, consistent with the
point-to-point network type from Operational issue 3. Configs:
`configs/sha256/` (all four routers).

## Security note

Key strings used throughout (`SharedSecret123`, `LabSecret2026`) are
illustrative lab placeholders, not production credentials, and do not
resemble any real password.

