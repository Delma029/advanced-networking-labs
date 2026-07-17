# TCP BDP / CUBIC vs BBR Lab Environment

Ubuntu VM. Two endpoints, TCPA (10.10.10.1) and TCPB (10.10.10.2), as
Linux network namespaces connected via a veth pair. No FRR/routing —
just two hosts on one direct link.

## Namespace and link setup
sudo ip netns add TCPA
sudo ip netns add TCPB
sudo ip link add veth-tcp-a type veth peer name veth-tcp-b
sudo ip link set veth-tcp-a netns TCPA
sudo ip link set veth-tcp-b netns TCPB
sudo ip netns exec TCPA ip link set lo up
sudo ip netns exec TCPA ip addr add 10.10.10.1/30 dev veth-tcp-a
sudo ip netns exec TCPA ip link set veth-tcp-a up
sudo ip netns exec TCPB ip link set lo up
sudo ip netns exec TCPB ip addr add 10.10.10.2/30 dev veth-tcp-b
sudo ip netns exec TCPB ip link set veth-tcp-b up

Raw link baseline (no shaping): sub-millisecond RTT, ~15.6 Gbit/s
iperf3 throughput — confirms this is a memory-speed virtual link with
nothing in common with a real long-haul path, which is the whole
reason for the shaping below.

## Simulated long-haul link: netem + tbf

Target scenario: 1 Gbps, ~200ms RTT, modeling an international research
link (e.g. RIKEN to a European partner). Delay applied symmetrically
(100ms each direction via netem) so the round trip totals ~200ms;
bandwidth capped via tbf since netem alone doesn't do rate shaping.
sudo ip netns exec TCPA tc qdisc add dev veth-tcp-a root handle 1: tbf rate 1gbit burst 1mbit latency 400ms
sudo ip netns exec TCPA tc qdisc add dev veth-tcp-a parent 1: handle 10: netem delay 100ms
sudo ip netns exec TCPB tc qdisc add dev veth-tcp-b root handle 1: tbf rate 1gbit burst 1mbit latency 400ms
sudo ip netns exec TCPB tc qdisc add dev veth-tcp-b parent 1: handle 10: netem delay 100ms

Verified: `ping` RTT settled at ~200-210ms after applying both qdiscs.

## Issue: tbf burst size was originally under-configured, and it mattered a lot

The link was first built with `burst 32kbit` (tc reports this as ~4Kb).
Buffer tuning (below) alone produced almost no improvement — 22.4 Mbit/s
baseline to only 27.9 Mbit/s tuned, and even a 120-second run showed
Cwnd oscillating in a fixed ~1-1.7MB band rather than climbing toward
the 25MB BDP target. Raising tbf's burst to `1mbit` (~128Kb as reported
by tc) was the actual fix: the same buffer-tuned configuration then
reached 588 Mbit/s over 60 seconds, with Cwnd stabilizing at 42.3MB —
above the BDP target. Buffer ceiling and shaper burst size were both
necessary; neither alone was sufficient. See
`03-tcp-bdp-cubic-bbr/results/txt/bdp-prediction.txt` for the full,
step-by-step diagnostic trail.

## BDP calculation and prediction

Bandwidth-delay product: 1 Gbps x 200ms RTT ≈ 25,000,000 bytes (~25 MB)
— the data that must be in flight, unacknowledged, to fully use the
link.

Default Linux buffer ceilings, checked before testing:
net.core.rmem_max / wmem_max: 212,992 bytes (~208 KB)
net.ipv4.tcp_rmem max:        33,554,432 bytes (~32 MB) — exceeds BDP
net.ipv4.tcp_wmem max:         4,194,304 bytes (~4 MB)  — ~6x under BDP

Prediction written down before testing: the send-side buffer
(tcp_wmem) would bottleneck first, since it sits well under the 25MB
BDP target while the receive side already has headroom above it.

## Buffer tuning
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem="4096 131072 33554432"
net.ipv4.tcp_wmem="4096 65536 33554432"

Applied on both TCPA and TCPB. Note: `net.core.rmem_max`/`wmem_max`
returned "Operation not permitted" when set from inside a namespace —
these are true global kernel parameters shared host-wide, not
namespace-aware, and cannot be overridden per-namespace even as root.
`tcp_rmem`/`tcp_wmem` are namespace-aware and applied successfully;
since TCP's own auto-tuning reads its ceiling from these two values
(not from `core.rmem_max`), this was sufficient for the experiment
despite the two global values staying at their small defaults.

## Congestion control: CUBIC and BBR

Kernel shipped with `reno` and `cubic` available by default; `bbr`
required `sudo modprobe tcp_bbr` before appearing in
`net.ipv4.tcp_available_congestion_control`. Switched globally via
`sysctl -w net.ipv4.tcp_congestion_control=<algo>`, verified with a
read-back before every test.

## Issue: run-to-run throughput variance on this link is real and large

Solo CUBIC throughput varied from 335 Mbit/s to 522-588 Mbit/s across
different sessions on an identically-configured link — genuine
variance from queue state and timing, not config drift. Any single-run
result here is approximate; comparative claims (e.g. CUBIC vs BBR
fairness) needed multiple independent runs before being trusted.

## Concurrent CUBIC vs BBR testing

Two simultaneous flows require two iperf3 server instances on
different ports and two client invocations backgrounded together:
sudo ip netns exec TCPB iperf3 -s -p 5201 -D
sudo ip netns exec TCPB iperf3 -s -p 5202 -D
sudo ip netns exec TCPA iperf3 -c 10.10.10.2 -p 5201 -C cubic -t 60 > cubic-side.txt &
sudo ip netns exec TCPA iperf3 -c 10.10.10.2 -p 5202 -C bbr -t 60 > bbr-side.txt &
wait

`wait` blocks until both backgrounded clients finish, ensuring the two
flows genuinely overlap and compete for the same link/queue at the
same time rather than running sequentially. `pkill iperf3` plus a short
sleep before each new round prevented stale server processes from a
prior test interfering with the next.

## Verified baselines

Default buffers + original small burst: 22.4 Mbit/s (~2% of 1 Gbps).
Tuned buffers + corrected burst, 60s: 588 Mbit/s, Cwnd stable at
42.3MB, above the BDP target.
