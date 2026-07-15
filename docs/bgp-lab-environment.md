# BGP Lab Environment

Ubuntu VM, FRRouting 10.6.1. Three ASes as Linux network namespaces
(R1BGP/AS100, R2BGP/AS200, R3BGP/AS300), veth-linked, each running
independent zebra/bgpd/mgmtd via `-N <pathspace>`.

Topology:
- R1BGP (AS100) -- R2BGP (AS200): 10.0.0.0/30
- R2BGP (AS200) -- R3BGP (AS300): 10.0.1.0/30

R3BGP originates 172.16.30.0/24. R2BGP is the transit AS.

## Issue: interface names over 15 characters silently fail

`veth-as100-as200` (17 chars) exceeds Linux's IFNAMSIZ limit and the
kernel rejects it outright — cascades into "cannot find device" errors
on every dependent command. Kept all veth names under 15 characters
(e.g. `veth-as1-as2`) from then on.

## Issue: BGP requires explicit address-family activation and policy

Unlike OSPF, declaring `neighbor X remote-as Y` alone does not exchange
any routes. FRR requires:
1. `neighbor X activate` under `address-family ipv4 unicast` (though in
   practice this may already default to enabled — see next issue)
2. An explicit route-map or prefix-list applied inbound/outbound, or
   FRR discards everything by default with "updates discarded due to
   missing policy" — a real safety-by-default behavior, not a bug.

## Issue: long, nested vtysh -c chains are unreliable on this build

Any `vtysh -c "configure terminal" -c "router bgp X" -c "address-family
..." -c "neighbor ... activate" -c "end"` chain silently dropped steps
partway through, repeatedly, across multiple routers, with no error
shown. Flat single-level commands (`vtysh -c "show ..."`) always worked.
**Fix: pipe multi-line config into vtysh via heredoc instead:**
sudo ip netns exec R2BGP vtysh -N R2BGP
configure terminal
router bgp 200
address-family ipv4 unicast
neighbor X activate
end
write memory

This uses vtysh's normal line-by-line interactive parsing rather than
the `-c` flag mechanism, and was reliable every time it was tried.

## Issue: zebra silently fails to install `ip route ... Null0` / `blackhole`

Config-file and interactive `ip route <prefix> Null0` (and `blackhole`)
were both accepted with zero error by vtysh's `?` help and by
`configure terminal`, yet never appeared in `show ip route` — no error,
no warning, just silently absent. The zebra log eventually revealed:
`No such command on config line N: ip route ... Null0` — even though
the same syntax is valid per vtysh's own tab-completion. Root cause not
fully resolved; appears specific to this FRR build's static-route
subsystem when routes are added via zebra's own config path.

**Fix: install the route directly via the Linux kernel instead of
through zebra:**

sudo ip netns exec R3BGP ip route add blackhole 172.16.30.0/24

Confirmed via raw `ip route show` that the kernel accepts this
instantly, in both the default namespace and inside R3BGP. zebra then
correctly *displays* this as a `K` (kernel) route in `show ip route` —
proving zebra's read/display path works fine; only its own
static-route *installation* path is broken. This kernel-level route was
sufficient to satisfy BGP's `network` statement requirement for a
matching RIB entry, and propagation worked correctly once this was in
place. Since this route doesn't persist across a VM reboot (unlike
FRR config files), it must be reissued each session alongside the
namespace/veth setup.

## Verified working baseline

R1BGP (no direct link to AS300) correctly shows 172.16.30.0/24 with
AS-path `200 300`, next-hop 10.0.0.2 (R2BGP) — confirming real
multi-hop eBGP transit, not just session establishment.
EOF

git add docs/bgp-lab-environment.md
git commit -m "02-bgp: lab environment doc — interface naming, policy defaults, vtysh heredoc fix, zebra static-route bug"

