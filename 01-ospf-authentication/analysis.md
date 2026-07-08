# Analysis: OSPF Authentication — Cost and Security Value

## Phase 1: No-authentication baseline

**Expected:** OSPF would converge normally with no security at all, since
no auth is configured on any router.

**Observed:** All three links converged to Full, R1 gained end-to-end
routes to R3 and R4 through R2, confirmed via `show ip route ospf`.

**Why:** OSPF has no built-in trust requirement by default — any device
speaking the protocol correctly on a shared link is treated as a
legitimate neighbor.

**RFC context:** RFC 2328 defines OSPF's authentication field as optional,
defaulting to type 0 (no authentication).

**Real-world implication:** in this state, any device with physical or
logical access to a link can join the OSPF domain. This is the baseline
every later phase is measured against.

## Phase 2: MD5 authentication

**Expected:** applying MD5 to only one side of a link would break that
specific adjacency, since MD5 requires both ends to sign and verify with
a matching key.

**Observed:** exactly that. R1 configured alone caused R2 to vanish from
R1's neighbor table within ~15 seconds, and vice versa. No error message
on either side — the neighbor simply stopped appearing. Recovered to
Full within ~20 seconds once R2 was given a matching key.

**Why:** MD5 mode appends a 128-bit digest to every OSPF packet on that
interface. The receiver recomputes the digest itself; if it doesn't
match, the packet is dropped before it ever reaches the OSPF state
machine, so the failure is silent rather than an active rejection message.

**RFC context:** RFC 2328 Appendix D / RFC 5709 background — cryptographic
authentication was added to protect against exactly this kind of silent
neighbor forgery.

**Real-world implication:** MD5 mismatches fail *silently* — an operator
watching this without knowing an auth change was made would see a mystery
outage with no obvious cause pointing at authentication specifically.

## Phase 3: HMAC-SHA-256 authentication

**Expected:** same break/recover pattern as MD5, since the underlying
mechanism (keyed digest, sender signs, receiver verifies) is conceptually
identical, just with a longer digest and different FRR config syntax
(key chain vs. interface-local key).

**Observed:** confirmed — same silent failure and recovery pattern on
R1-R2. Extended topology-wide to R2-R3 and R2-R4 directly (skipping MD5
on those links, since the mismatch mechanism was already proven on R1-R2).
Notably, R2-R3 and R2-R4 retained their pre-existing uptime when SHA-256
was applied on top of an already-Full adjacency — FRR enforces auth going
forward from the next hello, not retroactively on an existing session.

**Why:** structurally the same mechanism as MD5, stronger digest (256-bit
vs 128-bit).

**RFC context:** RFC 5709 defines HMAC-SHA-256/384/512 support via
key-chain, as a replacement for the older, weaker MD5 mechanism in RFC 2328.

**Real-world implication:** SHA-256 is a drop-in strength upgrade from
MD5 with no behavioral downside observed in this lab.

## Phase 4: Packet overhead analysis

**Expected:** MD5 and SHA-256 would add a fixed number of bytes to every
OSPF packet on an authenticated interface, roughly matching their digest
length (128-bit / 16-byte for MD5, 256-bit / 32-byte for SHA-256).

**Observed:** confirmed exactly, across two different packet types:

| Packet type | No-auth | MD5 | SHA-256 |
|---|---|---|---|
| Hello | 82 bytes | 98 bytes | 114 bytes |
| LS-Update (smallest) | 122 bytes | 138 bytes | 154 bytes |

Both packet types show identical +16 bytes for MD5 and +16 more (+32
total) for SHA-256, regardless of the packet's own size or type. Verified
directly against the `Auth Crypt Data Length` field inside each packet
(16 for MD5, 32 for SHA-256) and the actual digest bytes visible in
`Auth Crypt Data` — the frame-size difference and the stated digest
length agree exactly.

**Why:** authentication overhead in OSPF is a fixed-size trailer appended
after the OSPF header, independent of the packet's payload — the digest
covers the packet contents but its own size never varies for a given
algorithm.

**RFC context:** RFC 2328 defines the 16-byte auth field structure for
MD5; RFC 5709 extends this to variable-length digests for HMAC-SHA
family, explaining the exact 32-byte figure for SHA-256.

**Real-world implication:** overhead is small in absolute terms (32 bytes
on even a 44-byte Hello is still under 100 bytes total) but is paid on
*every* packet, at *every* Hello interval, on *every* authenticated
interface — the cost scales with neighbor count and traffic volume, not
with a one-time setup cost. This connects directly to the CPU findings in
Phase 5: the byte overhead is fixed and measurable, but the corresponding
CPU cost of processing it turned out to be too small to detect at this
lab's scale.

## Phase 5: CPU cost — MD5 vs SHA-256

**Expected:** SHA-256, computing a longer digest, would show measurably
higher CPU usage than MD5, especially on R2 (3 authenticated neighbors)
versus R1 (1 neighbor).

**Observed:** across 3 trials each, R2 averaged 0.26% CPU under MD5 and
0.27% under SHA-256 — a 0.01-point difference. R1 averaged 0.09% and
0.08% respectively. In both cases, the trial-to-trial variation *within*
one algorithm (e.g., MD5 ranged 0.13-0.37% across its 3 trials) was
larger than the gap *between* algorithms.

**Why:** cryptographic hashing over a small OSPF control-plane packet, at
this topology's low packet rate (Hello every 10s, LSA retransmit every
5s), is computationally trivial for a modern general-purpose CPU
regardless of digest length. The measured "difference" is smaller than
normal scheduling/timing noise.

**RFC context:** neither RFC specifies expected computational cost —
this is an implementation/hardware question, not a protocol one.

**Real-world implication:** at this scale, there is no practical reason
to prefer MD5 over SHA-256 on CPU-cost grounds — the security upgrade is
effectively free here. This might not hold at much higher LSA-flood
rates, or on constrained hardware without hardware crypto acceleration
(e.g., a Raspberry Pi) — flagged as a limitation of this lab's scale, not
a claim that the cost is universally zero.

## Phase 7: Rogue router — [to be completed]

## Conclusion — [to be completed once Phase 7 is done]

## Future work

This project was deliberately scoped to OSPF's built-in authentication.
Extending this same cost/security framework to eBGP session authentication
and RPKI-based route origin validation — which govern trust *between*
autonomous systems rather than within one — was considered but not
executed here.
