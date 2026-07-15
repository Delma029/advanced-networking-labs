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



## Phase 3: Same-prefix hijack (AS400 vs AS300)

AS400 peered with AS200 and originated 172.16.30.0/24 — the exact prefix
already legitimately owned by AS300 — with an identical AS-path length
(1 hop: `400` vs `300`).

**Result: hijack did not win.** R2BGP's `show ip bgp` shows both paths,
but `*>` (best) remained on AS300's route. R1BGP's table shows only
`200 300` — R2 never propagated AS400's path onward, since BGP only
advertises its single best path per neighbor, not all candidates.

**Why:** with AS-path length tied, FRR's best-path algorithm falls
through to further tiebreakers. The deciding one here was "prefer the
route received first" — AS300's session had been established ~16
minutes before AS400's. This is confirmed by R1BGP's path detail:
`Origin IGP, valid, external, best (First path received)`.

**Significance:** the legitimate route won by accident of session
timing, not because BGP validated anything about the announcement's
authenticity. Had AS400 peered before AS300, or had AS300's session
flapped and re-established after AS400's, the hijack would have won
outright with identical configuration. This demonstrates BGP's core
security gap directly: no cryptographic or authoritative check exists
to distinguish a legitimate origin AS from an attacker's — origin
validation (RPKI, Phase 5) exists specifically to close this gap.

## Phase 4: Sub-prefix hijack (AS400 announces 172.16.30.0/25)

AS400 re-announced a more specific sub-prefix of AS300's legitimate
block (`/25` instead of `/24`) rather than competing on the same prefix.

**Result: hijack succeeded outright.** Both routes now coexist in every
router's table — `172.16.30.0/24` (AS300, legitimate) and
`172.16.30.0/25` (AS400, attacker) — each independently marked `*>`
(best), since longest-prefix-match treats them as different
destinations rather than competing paths for the same one.

**Traffic impact confirmed:** `show ip route 172.16.30.10` on R1BGP
(an address falling inside AS300's real block but also inside AS400's
announced /25) resolves via the `/25` route, path `200 400` — traffic
to that address is actually diverted to the attacker, not just visible
as a redundant table entry.

**Why this differs fundamentally from Phase 3:** in the same-prefix
case, only one path could win, and the outcome hinged on an arbitrary
tiebreaker (session arrival order). Here, no tiebreaker is even
consulted — longest-prefix-match is a hard rule with no ambiguity, so
the hijack succeeds unconditionally regardless of AS-path length,
session timing, or any other BGP attribute. This is the real-world
mechanism behind incidents like the 2008 Pakistan Telecom/YouTube
hijack, and it demonstrates that BGP has no defense against a more
specific, illegitimately-originated announcement — origin validation
(RPKI, Phase 5) is designed specifically to close this gap by
cryptographically tying a prefix (down to a maximum allowed length) to
its legitimate origin AS.
