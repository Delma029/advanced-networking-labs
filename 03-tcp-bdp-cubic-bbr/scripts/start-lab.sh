#!/bin/bash
set -e

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

# net.core.rmem_max/wmem_max are global, not namespace-aware -- they
# fail with "Operation not permitted" inside a namespace even as root.
# Documented in tcp-lab-environment.md. Non-fatal by design: the
# tcp_rmem/tcp_wmem lines below are namespace-aware and are what
# actually governs TCP's buffer auto-tuning ceiling.
for ns in TCPA TCPB; do
  sudo ip netns exec $ns sysctl -w net.core.rmem_max=33554432 2>/dev/null || true
  sudo ip netns exec $ns sysctl -w net.core.wmem_max=33554432 2>/dev/null || true
  sudo ip netns exec $ns sysctl -w net.ipv4.tcp_rmem="4096 131072 33554432"
  sudo ip netns exec $ns sysctl -w net.ipv4.tcp_wmem="4096 65536 33554432"
done

# Simulated link: 1 Gbps, ~200ms RTT, corrected 1mbit burst (original
# 32kbit/4Kb burst was too shallow -- see tcp-lab-environment.md)
sudo ip netns exec TCPA tc qdisc add dev veth-tcp-a root handle 1: tbf rate 1gbit burst 1mbit latency 400ms
sudo ip netns exec TCPA tc qdisc add dev veth-tcp-a parent 1: handle 10: netem delay 100ms
sudo ip netns exec TCPB tc qdisc add dev veth-tcp-b root handle 1: tbf rate 1gbit burst 1mbit latency 400ms
sudo ip netns exec TCPB tc qdisc add dev veth-tcp-b parent 1: handle 10: netem delay 100ms

sudo modprobe tcp_bbr

echo "-- link check --"
sudo ip netns exec TCPA tc qdisc show dev veth-tcp-a
echo "-- connectivity check --"
sudo ip netns exec TCPA ping -c 2 10.10.10.2
