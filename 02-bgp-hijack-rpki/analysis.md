# Analysis: BGP Hijacking and RPKI-Equivalent Mitigation

## Phase 1-2: Baseline eBGP peering and normal routing

**Expected:** three-AS topology (AS100-AS200-AS300) would establish
eBGP sessions and correctly propagate an originated prefix across two hops.

**Observed:** R3BGP (AS300) originated 172.16.30.0/24. R1BGP, with no
direct connection to AS300, correctly learned it with AS-path 200 300
and next-hop 10.0.0.2 (its actual neighbor, R2BGP) — confirming genuine
multi-hop transit, not just adjacent-session health.

**Why:** BGP is a path-vector protocol; each AS prepends itself to the
AS-path before re-advertising, and next-hop is set per-hop (unlike
OSPF's end-to-end reachability model), which is why R1BGP's next-hop is
R2BGP's address, not R3BGP's.

**RFC context:** RFC 4271 defines the AS-path attribute and its role in
loop prevention and path selection.

## Phase 3: Same-prefix hijack

**Expected:** AS400 announcing the identical 172.16.30.0/24 already
owned by AS300 would create a contest resolved by BGP's best-path
algorithm.

**Observed:** both paths appeared in R2BGP's table with equal AS-path
length (1 hop each). AS300's path won via the "first path received"
tiebreaker — a real BGP best-path rule, not a security mechanism.

**Why this matters:** the legitimate route survived by timing luck, not
because BGP has any concept of "the real owner." Had AS400 been
configured before AS300, it would have won outright with an identical
config. This demonstrates same-prefix hijacking is non-deterministic —
success or failure depends on session ordering, not on which
announcement is true.

**RFC context:** RFC 4271 S9.1.2.2 defines the best-path tiebreakers,
including path age, entirely orthogonal to origin authenticity.

**Real-world implication:** relying on BGP's default best-path selection
to reject a same-prefix hijack is relying on luck, not a defense.

## Phase 4: Sub-prefix hijack

**Expected:** AS400 announcing a more specific sub-prefix
(172.16.30.0/25) of AS300's block would win regardless of AS-path
length or tiebreakers, since longest-prefix-match always overrides
best-path selection at the forwarding stage.

**Observed:** confirmed — the /25 announcement was accepted and
installed, diverting traffic destined for that half of the block to
AS400's blackhole, with no contest or tiebreak involved at all.

**Why:** unlike Phase 3, there's no competition between two paths for
the same prefix — longest-prefix-match is a forwarding-table rule that
applies independently of any BGP path-selection process. A /25 always
wins over a /24 for addresses inside it.

**RFC context:** longest-prefix-match is fundamental IP forwarding
behavior (RFC 1519), not a BGP-specific rule — which is exactly why
BGP's own path-selection tiebreakers, however they're configured,
cannot defend against this attack.

**Real-world implication:** this is the deterministic, guaranteed
version of hijacking, and the one real internet routing incidents
typically use — no timing luck required, no dependency on
configuration order.

## Phase 5: RPKI-equivalent mitigation

**Scope decision:** genuine FRR RPKI requires the frr-rpki-rtrlib
package and a running RTR cache server (e.g. Routinator) — standing
this up was scoped out as infrastructure work tangential to
demonstrating origin validation's actual security effect. The ROA
decision a real validator would produce for this scenario
("172.16.30.0/24, max-length /24, origin AS300 only") was instead
encoded directly as an inbound route-map/prefix-list on R1BGP.

**Observed:** AS400's 172.16.30.0/25 announcement no longer appears in
R1BGP's table at all — rejected inbound, before ever entering the RIB.
Traffic to that block now correctly resolves via the legitimate
172.16.30.0/24 route.

**Note:** this route-map/prefix-list mechanism is also, functionally,
what "prefix filtering" as a mitigation technique refers to — a
separate phase testing prefix filtering as a distinct mitigation was
not run, since this phase already demonstrates the mechanism directly.

**Why:** origin validation rejects announcements based on whether the
originating AS is authorized for that specific prefix/length — a check
BGP has no native concept of, which is exactly the gap RPKI exists to
close.

**RFC context:** RFC 6811 defines BGP origin validation using ROAs;
RFC 6810 defines the RTR protocol used to distribute them, which this
lab simplified around while preserving the actual validation logic.

**Real-world implication:** this is the direct fix for Phase 4's
deterministic hijack, and — unlike the tiebreaker luck in Phase 3 —
doesn't depend on configuration order or timing at all.

## Conclusion

Phase 3 showed that BGP's default behavior offers no real protection
against a same-prefix hijack — only accidental timing. Phase 4 showed
sub-prefix hijacking is worse still: deterministic, guaranteed, immune
to any path-selection tiebreaker. Phase 5 showed that origin validation
— checking whether an AS is actually authorized to announce a given
prefix, which is precisely what RPKI provides in production — closes
this gap completely and deterministically, regardless of announcement
order.

## Future work

Route leaks (a transit AS improperly re-advertising a route to a peer
it shouldn't, without any forged origin) were scoped out — a
mechanistically distinct problem from hijacking that would require
modeling real customer/peer/provider policy relationships this
topology doesn't represent. RPKI was demonstrated via an equivalent
route-map rather than a live RTR cache server (Routinator); a full
implementation would additionally validate against live ROA data
rather than a manually authored policy.
