# Analysis: TCP BDP, Buffer Tuning, and CUBIC vs BBR Fairness

## Phase 1: BDP calculation and default-buffer baseline

**Expected:** on a simulated 1 Gbps / ~200ms RTT link (25MB BDP),
default tcp_wmem (4MB max) would bottleneck throughput well below line
rate; tcp_rmem (32MB max) should not, since it already exceeds the BDP.

**Observed:** 22.4 Mbit/s average over 20s — ~2% of the 1 Gbps link,
worse than a rough 150-200 Mbit/s pre-test estimate. Cwnd climbed from
~206KB to ~1.42MB over the run — real AIMD growth, but far too slow
relative to the 25MB target because each growth step is gated by one
~200ms RTT.

**Why:** send buffer ceiling caps in-flight unacknowledged data
regardless of what the link could otherwise carry.

**Real-world implication:** default Linux buffer limits are tuned for
short-RTT LAN paths, not long-haul high-BDP research links.

## Phase 2: Buffer tuning, and the tbf burst discovery

**Expected:** raising tcp_wmem/tcp_rmem above the 25MB BDP would let
TCP's existing growth process close most of the gap to line rate.

**Observed:** raising buffers alone barely moved the needle — 27.9
Mbit/s over 20s (vs 22.4 baseline), and a 120-second extended run
showed Cwnd oscillating in a fixed ~1.0-1.7MB band the entire time,
never trending toward 25MB despite far more time to grow. This ruled
out both "buffer ceiling" and "just needs more time" as the actual
constraint. Investigating the link's own shaping configuration
revealed tbf's burst parameter was set to only ~4Kb on a 1gbit-rate
shaper — a mismatch severe enough to impose its own hard ceiling
independent of TCP's buffers. Raising burst to ~128Kb, same tuned
buffers, produced a fundamentally different result: Cwnd broke through
the old ceiling and, given 60 seconds, stabilized at 42.3MB (above the
BDP target) with throughput settling at 588 Mbit/s.

**Why:** three separate factors had to be corrected together, not one:
buffer ceiling above the BDP, a shaper burst size not artificially
capping throughput below what the buffers could otherwise support, and
sufficient test duration for RTT-gated AIMD growth to actually reach
steady state. Any one fix alone was insufficient.

**Real-world implication:** naive buffer tuning based on a BDP
calculation alone is necessary but not sufficient — a link's traffic
shaping configuration can silently override buffer tuning entirely, and
this is easy to miss if throughput is only checked over a short test
window.

## Phase 3: Parallel streams

**Expected:** per the classic diminishing-returns model, throughput
should improve with more parallel streams, each gain smaller than the
last.

**Observed:** an initial 30-second sweep (1/2/4/8/16 streams) appeared
to show a peak at 2 streams followed by degradation — but single-stream
throughput in that sweep (160 Mbit/s) was far below the 588 Mbit/s
single-stream figure established in Phase 2, because 30 seconds isn't
enough time for CUBIC to reach its own steady state on this link
(established as needing ~8+ seconds just to break past its initial
ramp-up). A corrected 60-second sweep, fair to all stream counts,
showed no benefit from parallel streams at any count: 1 stream reached
522 Mbit/s alone; 2 streams performed slightly worse (454 Mbit/s); 4
streams gained only ~7% (561 Mbit/s) at the cost of 6.7x more
retransmissions (601 vs 90); 8 and 16 streams collapsed well below
single-stream performance (241 and 136 Mbit/s).

**Why:** parallel streams help when a single flow cannot grow its
window fast enough to use an otherwise-idle path. Here, single-stream
CUBIC was already capable of reaching the link's practical ceiling
given adequate time — so additional streams only added contention for
the same shaped queue, without solving a problem that didn't exist at
this test duration.

**Real-world implication:** "more parallel streams equals more
throughput" is not a universal rule — it depends on whether the
bottleneck is a single flow's window growth or shared queue capacity.
Testing with too short a duration can produce a misleading "sweet spot"
that vanishes under fair, longer testing — a methodological trap worth
naming explicitly given it happened here first before being corrected.

## Phase 4: CUBIC vs BBR, solo

**Expected:** broadly comparable throughput between algorithms at this
point (link no longer buffer- or shaper-limited), but different
retransmission signatures — CUBIC (loss-based) expected higher,
BBR (model-based) expected lower.

**Observed:** CUBIC 335 Mbit/s (101 retransmits); BBR 305 Mbit/s (44
retransmits) — throughput within ~10%, but BBR used under half CUBIC's
retransmissions to get there. Note: this CUBIC figure is well below the
588 Mbit/s solo result from Phase 2's confirmation run — consistent
with the documented run-to-run variance on this link (see
lab-environment.md), not a contradiction.

**Why:** CUBIC grows until loss occurs and treats loss as its
backoff signal; BBR estimates bandwidth/RTT directly and paces to that
estimate, generally avoiding the need to induce loss to find its rate.

## Phase 5: CUBIC vs BBR, concurrent fairness

**Expected:** uncertain going in — published BBR research most often
describes BBR out-competing and starving CUBIC, particularly on
deep-buffer links.

**Observed — the opposite of the commonly-cited result, confirmed
across three independent runs:**

| | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| CUBIC | 305 Mbit/s, 2 retr (~87%) | 375 Mbit/s, 17 retr (~81%) | 305 Mbit/s, 2 retr (~87.5%) |
| BBR | 43.4 Mbit/s, 0 retr (~13%) | 90.6 Mbit/s, 0 retr (~19%) | 43.4 Mbit/s, 0 retr (~12.5%) |

CUBIC took the large majority share of the shared link in all three
trials (81-87.5%). BBR recorded zero retransmits in every run. The
exact split varied (consistent with this link's documented variance),
but the qualitative direction — CUBIC dominates, BBR retreats — held
in all three.

**Why:** this link's tbf queue is shallow (400ms max latency, small
burst even after correction). CUBIC is loss-based and keeps growing
its window until a packet actually drops, filling and holding the
shallow queue. BBR estimates available bandwidth from RTT samples; a
queue kept full by CUBIC inflates BBR's RTT readings, which BBR
interprets as the link being saturated, causing it to back off
pre-emptively — even though physical capacity remains, it's occupied by
CUBIC's queue backlog rather than genuinely exhausted. Zero
retransmits on BBR across all three runs is consistent with this: BBR
never pushes hard enough to trigger loss, it retreats on a
CUBIC-distorted delay signal alone.

**Real-world implication:** fairness between loss-based and delay-based
congestion control is not a fixed property of the two algorithms — it
depends heavily on the bottleneck's buffer depth. Shallow buffers (as
in this lab) favor CUBIC; published research on deep-buffer links more
often shows the reverse. Choosing or mixing congestion control
algorithms in a real deployment requires knowing the actual queue depth
of the bottleneck, not assuming a newer algorithm behaves identically
everywhere.

## Results summary

| Phase | Metric | Result |
|---|---|---|
| 1 | Default-buffer throughput | 22.4 Mbit/s (~2% of 1 Gbps) |
| 2 | Buffer-tuned only (small burst) | 27.9 Mbit/s — buffer tuning alone insufficient |
| 2 | Buffer-tuned + corrected burst, 60s | 588 Mbit/s, Cwnd stable at 42.3MB |
| 3 | Parallel streams (fair 60s test) | No benefit at any count; 8/16 streams collapse |
| 4 | CUBIC solo | 335 Mbit/s, 101 retr |
| 4 | BBR solo | 305 Mbit/s, 44 retr |
| 5 | CUBIC concurrent share | 81-87.5% (3 runs) |
| 5 | BBR concurrent share | 12.5-19% (3 runs) |

## Conclusion

This lab set out to answer three questions: does buffer tuning actually
fix a high-BDP link the way theory predicts; do parallel streams reduce
this project's dependence on any of that; and how do CUBIC and BBR
behave, both alone and competing for the same link.

The buffer question had a more complicated answer than the textbook
version: buffer tuning was necessary but not sufficient on its own — a
misconfigured shaper burst size silently capped throughput regardless
of buffer ceiling, and only correcting both together, combined with
adequate test duration, actually reached target throughput (588 Mbit/s,
Cwnd above the BDP).

The parallel-streams question had a genuinely negative answer once
tested fairly: no benefit at any stream count on this link, once
single-stream was given time to reach its own steady state — directly
contradicting the "diminishing returns, still helps a little" framing
this experiment is usually built around.

The CUBIC vs BBR question produced the most valuable, least expected
result: CUBIC consistently dominated BBR on this shallow-buffer link
across three independent trials, the reverse of BBR's most commonly
cited behavior in the literature — a result that only makes sense once
the buffer-depth-dependent mechanism is understood, and a concrete
demonstration that congestion-control fairness is conditional on
network conditions, not a fixed property of the algorithms.

## Future work

**Buffer-depth sweep:** systematically varying tbf's queue depth while
re-running the CUBIC-vs-BBR concurrent test at each depth would map the
crossover point where the fairness result flips — the single biggest
open question this lab's fixed shallow-buffer setup couldn't answer.

**More trials:** three runs confirmed the qualitative direction of the
fairness result; a properly powered comparison (10+ runs) would allow a
real confidence interval on the exact share split.

**Additional algorithms:** only CUBIC and BBR were tested; Reno was
available but not evaluated, and BBRv2/v3 were not tested at all.

**Real hardware/WAN:** this entire lab used netem/tbf on a single VM —
a genuine long-haul path or real research-network link could behave
differently in ways a software-simulated link cannot fully capture.

## Phase 2b: tbf burst-size correction (methodology note)

**What happened:** after fixing the confirmed send-buffer bottleneck
(Phase 1-2), throughput was still far below expectations (27.9 Mbit/s).
This didn't match the theory -- buffer ceiling was no longer the
constraint, yet throughput barely moved from the unbuffered baseline.

**Root cause:** the link's `tbf` qdisc had `burst 32kbit` (4KB) -- a
second, independent bottleneck unrelated to TCP buffer tuning. `tbf`'s
burst parameter controls the token bucket's allowed burst size, not
the sustained rate (`rate 1gbit` was already correctly set); too small
a burst throttles real throughput even when the configured rate would
allow more.

**Fix and verification:** raised burst to `1mbit` (128KB), then ran a
controlled side-by-side comparison at both settings on an otherwise
identical link to confirm burst -- not something else -- was the cause:

  Small burst (32kbit):  results/csv/tuned-small-burst-confirm.json
  Large burst (1mbit):   results/csv/tuned-buffers-larger-burst.json

All subsequent tests (Phases 3-4: CUBIC/BBR solo and concurrent) used
the corrected 1mbit burst.

**Why this belongs in the report:** this is a real methodology error,
caught and corrected mid-project, not hidden after the fact. It's also
a genuine finding in its own right: BDP theory alone (buffer size vs.
RTT x bandwidth) doesn't fully describe achievable throughput on a
software-simulated link -- queueing-discipline parameters like tbf's
burst size can independently bottleneck a link in ways the BDP
calculation doesn't predict or explain.
