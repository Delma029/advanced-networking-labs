# Advanced Networking Labs

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
Lab setup and debugging notes: [`docs/lab-environment.md`](docs/lab-environment.md)
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
namespaces connected via veth pairs. See `docs/lab-environment.md` for
setup and every real problem hit along the way.
