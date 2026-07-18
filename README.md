# Advanced Networking Labs

Three projects, one underlying question: what does a protocol or
mechanism actually cost, and what does it actually protect against —
measured, not assumed. OSPF and BGP both test authentication/validation
mechanisms against real attacks in a live topology. TCP tests whether
textbook tuning advice (buffer sizing, parallel streams, newer
congestion control) actually holds up under real, measured conditions
on a deliberately realistic simulated link. All three surfaced at least
one result that contradicted the "expected" textbook answer, and all
three document the real debugging process, not just the clean final
numbers.

## Project 1: OSPF Authentication Analysis

What does it actually cost to secure OSPF, and is that cost worth it?
This project compares no authentication, MD5, and HMAC-SHA-256 across
packet overhead, CPU usage, convergence time, and — the actual point of
the whole thing — whether they stop an unauthorized device from
hijacking the network.

**Short version of what I found:** the overhead is small and fixed (16
bytes for MD5, 32 for SHA-256, on every packet). CPU and convergence
cost were too small to reliably measure at this scale. The security
value is not small at all — an unauthenticated rogue router fully
hijacked the default route for a router it was never even directly
connected to, and SHA-256 shut that down completely.

Full write-up: [`01-ospf-authentication/analysis.md`](01-ospf-authentication/analysis.md)
Lab setup and debugging notes: [`docs/ospf-lab-environment.md`](docs/ospf-lab-environment.md)
Start with `01-ospf-authentication/results/txt/rogue-noauth-r1-route.txt`
vs `rogue-sha256-r1-route.txt` if you want the fastest way to see the
actual before/after — that's the whole project in two files.

### Structure

01-ospf-authentication/
├── configs/          saved router configs per auth mode
├── pcaps/            packet captures per auth mode
├── results/txt/      neighbor tables, route tables, observations
├── results/csv/      CPU sampling data (pidstat)
├── screenshots/       the few moments worth seeing, not reading
├── scripts/           start-lab.sh, capture-phase.sh
└── analysis.md        phase-by-phase findings and conclusion

### Environment

Ubuntu VM running FRRouting 10.6.1, four routers as Linux network
namespaces connected via veth pairs. See `docs/ospf-lab-environment.md` for
setup and every real problem hit along the way.

## Project 2: BGP Hijacking and RPKI-Equivalent Mitigation

Can a rogue AS actually steal traffic on the internet's real routing
protocol, and does the standard fix genuinely stop it?

This project builds a 3-AS eBGP topology, then introduces a 4th AS
(AS400) that attempts two different hijacks against a legitimate prefix
owned by AS300 — first announcing the identical prefix, then a more
specific sub-prefix — and tests whether origin validation (the concept
behind RPKI) actually stops it.

**Short version of what I found:** a same-prefix hijack is a coin
flip — BGP's default behavior only rejected it because the legitimate
route happened to be configured first; an identically-configured
attacker announced *before* the real owner would have won outright. A
sub-prefix hijack isn't a coin flip at all — it succeeds
unconditionally via longest-prefix-match, regardless of timing or
AS-path length, and actually diverted traffic in the lab. Origin
validation (RPKI's real job) closed both gaps completely: the attacker's
announcement was rejected before it ever entered the routing table.

Full write-up: [`02-bgp-hijack-rpki/analysis.md`](02-bgp-hijack-rpki/analysis.md)
Lab setup and debugging notes: [`docs/bgp-lab-environment.md`](docs/bgp-lab-environment.md)

Start with `02-bgp-hijack-rpki/results/txt/phase4-subprefix-r1-bgp-table.txt`
vs `phase5-rpki-mitigation-r1-bgp-table.txt` if you want the fastest way
to see the actual before/after — the attacker's route present, then gone.

### Structure

02-bgp-hijack-rpki/
├── configs/          saved router configs per phase
├── results/txt/      BGP tables, route resolutions, neighbor states
├── screenshots/       the few moments worth seeing, not reading
└── analysis.md        phase-by-phase findings and conclusion

### Environment

Same Ubuntu VM and FRRouting 10.6.1, three (later four) routers as
Linux network namespaces, veth-linked, running zebra/bgpd. See
`docs/bgp-lab-environment.md` for setup and every real problem hit
along the way — this project surfaced a distinct set of issues from
OSPF's, including a silent zebra static-route bug and vtysh's `-c`
flag chain dropping steps unpredictably (fixed via heredoc instead).

**Scope note:** RPKI's actual security decision (origin+prefix-length
validation) was demonstrated via an equivalent route-map/prefix-list
rather than a live RTR cache server — see `docs/bgp-lab-environment.md`
Phase 5 for the specific reasoning and what a full implementation would
add.

## Project 3: TCP BDP, Buffer Tuning, and CUBIC vs BBR Fairness

Does the textbook fix for a high-BDP link actually work, and does BBR
actually beat CUBIC the way it's usually described?

This project simulates a 1 Gbps / ~200ms RTT link (a stand-in for an
international research network path) using `netem` and `tbf`, then
tests default buffers against BDP-tuned ones, parallel TCP streams
against a single stream, and CUBIC against BBR — first alone, then
competing for the same link at the same time.

**Short version of what I found:** buffer tuning alone barely helped
(22.4 to 27.9 Mbit/s) — the real, hidden bottleneck was a misconfigured
traffic-shaper burst size that silently capped throughput regardless of
buffer ceiling; fixing both together reached 588 Mbit/s. Parallel
streams, tested fairly, gave no benefit at any stream count once
single-stream was given time to reach its own steady state — directly
against the "diminishing returns" framing most guides assume. And CUBIC
beat BBR badly in a head-to-head fight for the same link (81-87% share
across three runs) — the reverse of BBR's usual reputation, because
this link's shallow buffer queue plays to CUBIC's strengths, not BBR's.

Full write-up: [`03-tcp-bdp-cubic-bbr/analysis.md`](03-tcp-bdp-cubic-bbr/analysis.md)
Lab setup and debugging notes: [`docs/tcp-lab-environment.md`](docs/tcp-lab-environment.md)

Start with `03-tcp-bdp-cubic-bbr/results/txt/bdp-prediction.txt` for
the full before/after story in one file — the BDP math, the prediction,
and every test result compared against it in sequence.

### Structure

03-tcp-bdp-cubic-bbr/
├── configs/          sysctl values and tc/netem/tbf commands used
├── results/txt/      iperf3 output, BDP prediction and test log
├── results/csv/      raw JSON iperf3 output for graphing
└── analysis.md        phase-by-phase findings and conclusion

### Environment

Same Ubuntu VM, two Linux network namespaces connected directly via a
veth pair — no routing, no FRR. See `docs/tcp-lab-environment.md` for
the full setup and the tbf-burst debugging story that turned out to be
the most important finding in the project.
