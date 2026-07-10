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

## Phase 6: Convergence timing

**Expected:** SHA-256's larger digest computation might add measurable
time to adjacency re-establishment compared to MD5 and no-auth.

**Observed:** 3 trials each, triggered via `clear ip ospf process`,
timed from trigger to `Full` state:
| Trial | No-auth | MD5 | SHA-256 |
|---|---|---|---|
| 1 | 1.55s | 6.26s | 15.84s |
| 2 | 9.16s | 15.01s | 11.46s |
| 3 | 6.02s | 13.39s | 14.84s |
| Mean | 5.58s | 11.55s | 14.05s |

**Why the result is inconclusive, and that's the actual finding:** the
spread within each algorithm (MD5: 6.26-15.01s, a ~9s range) is larger
than the gap between the two means. This measurement is dominated by
where in the 10-second Hello interval the trigger happened to land, not
by authentication algorithm cost — a factor this experiment did not
control for. A reliable answer would need many more trials to average
out that timing variance, which was judged out of scope here.
One relatively clean signal survives the noise: no-auth's fastest trial
(1.55s) is faster than any MD5 or SHA-256 trial recorded, suggesting
authentication does add *some* real convergence delay — likely from the
extra digest verification step before a Hello is accepted as valid — even
though the exact magnitude can't be pinned down precisely at this sample
size.
**RFC context:** RFC 2328's convergence behavior (Hello/Dead intervals,
SPF scheduling) governs the dominant timing factor observed; digest
computation cost is not addressed by the RFC at all.

**Real-world implication:** consistent with Phase 5's CPU finding —
at this topology's scale, no reliable evidence that stronger
authentication meaningfully slows convergence. Both this result and
Phase 5 point the same direction: authentication cost, in time and CPU,
is dominated by other factors at small scale.


## Phase 7: Rogue router

**Expected:** an unauthenticated attacker with physical/logical access to
one link could inject false routing information; SHA-256 authentication
on that link should block it entirely.

**Observed:** with no authentication on the R2-ATTACKER link, the
attacker (router-id 9.9.9.9) formed a full OSPF adjacency and
successfully injected `default-information originate always` — a claimed
route to `0.0.0.0/0`. This propagated to R1, which has no direct
connection to the attacker at all, and R1 installed it as its selected,
FIB-active default route (`O>* 0.0.0.0/0 via 10.0.12.2`). A complete
routing hijack, with zero authentication required to pull it off.

Applying SHA-256 to only the R2-ATTACKER interface (attacker side left
unconfigured, since they have no way to know the key) did not
immediately drop the existing adjacency — same prospective-not-retroactive
enforcement seen in Phase 3. Forcing a full reconvergence (`clear ip ospf
process`) showed the real result: the three legitimate neighbors reformed
in 3-8 seconds, and the attacker's adjacency never reformed at all,
disappearing from the neighbor table entirely. R1's route table
confirmed `0.0.0.0/0` fully gone.

**Why:** identical mechanism to every MD5/SHA-256 mismatch already
observed — the attacker has no way to produce a valid keyed digest
without knowing the shared secret, so every packet it sends after
authentication is enabled gets silently dropped before reaching the OSPF
state machine, regardless of how convincingly it speaks the protocol
otherwise.

**RFC context:** RFC 2328 / RFC 5709 authentication exists specifically
to prevent this class of attack — this phase is the practical
demonstration of the threat model both RFCs' authentication sections are
written to defend against.

**Real-world implication:** this is the actual payoff of every other
phase in this project. The overhead measured in Phase 4, the CPU cost in
Phase 5, and the convergence timing in Phase 6 were all small or
statistically negligible — meanwhile, the security value demonstrated
here is total. A device with nothing but physical port access can
silently redirect an entire routing domain's traffic with no
authentication in place, and authentication closes that door completely,
at a cost too small to reliably measure at this scale.

## Results summary

| Phase | Metric | No-auth | MD5 | SHA-256 |
|---|---|---|---|---|
| 4 | Hello packet size | 82 bytes | 98 bytes | 114 bytes |
| 4 | LS-Update size (smallest) | 122 bytes | 138 bytes | 154 bytes |
| 5 | CPU, R2 (3 neighbors) | — | 0.26% avg | 0.27% avg |
| 5 | CPU, R1 (1 neighbor) | — | 0.09% avg | 0.08% avg |
| 6 | Convergence time (mean of 3) | 5.58s | 11.55s | 14.05s |
| 7 | Rogue router accepted? | Yes, full hijack | not tested | No, fully rejected |

Phase 6 numbers are noisy (see Phase 6 section) and shouldn't be read as
a precise ranking — the honest takeaway is "no reliably measurable time
cost," not "MD5 is faster."

## Conclusion

The starting question was whether OSPF authentication is worth its cost.
The answer, based on this lab: yes, clearly.

The measurable costs are all small. Overhead is a fixed 16 or 32 bytes
per packet depending on algorithm — real, but tiny next to a typical MTU.
CPU cost was statistically indistinguishable between MD5 and SHA-256 on
this topology. Convergence timing was too noisy to draw a firm
conclusion from, beyond a hint that some delay exists.

The security value, on the other hand, is not a matter of degree. Phase
7 showed a single unauthenticated device — no more access than a laptop
plugged into an open port — completely rewriting where an entire
network's traffic goes, without ever touching a router it wasn't
directly connected to. Enabling SHA-256 on that one link closed that off
entirely, at a cost too small to reliably measure anywhere else in this
project.

At the scale tested here, there's no real argument for running OSPF
without authentication, or for preferring MD5 over SHA-256 on
performance grounds. Whether these findings hold at higher route-churn
rates, larger topologies, or on constrained hardware is exactly the kind
of question flagged in Future work below.
