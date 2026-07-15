#!/bin/bash
set -e   # stop immediately on any error

# Namespaces — ephemeral, gone on reboot
for r in R1BGP R2BGP R3BGP R4BGP; do
  sudo ip netns add $r
done

# veth links — names kept under 15 chars (IFNAMSIZ limit, see bgp-lab-environment.md)
sudo ip link add veth-as1-as2 type veth peer name veth-as2-as1
sudo ip link add veth-as2-as3 type veth peer name veth-as3-as2
sudo ip link add veth-as2-as4 type veth peer name veth-as4-as2

sudo ip link set veth-as1-as2 netns R1BGP
sudo ip link set veth-as2-as1 netns R2BGP
sudo ip link set veth-as2-as3 netns R2BGP
sudo ip link set veth-as3-as2 netns R3BGP
sudo ip link set veth-as2-as4 netns R2BGP
sudo ip link set veth-as4-as2 netns R4BGP

# Addressing
sudo ip netns exec R1BGP ip link set lo up
sudo ip netns exec R1BGP ip addr add 10.0.0.1/30 dev veth-as1-as2
sudo ip netns exec R1BGP ip link set veth-as1-as2 up

sudo ip netns exec R2BGP ip link set lo up
sudo ip netns exec R2BGP ip addr add 10.0.0.2/30 dev veth-as2-as1
sudo ip netns exec R2BGP ip link set veth-as2-as1 up
sudo ip netns exec R2BGP ip addr add 10.0.1.1/30 dev veth-as2-as3
sudo ip netns exec R2BGP ip link set veth-as2-as3 up
sudo ip netns exec R2BGP ip addr add 10.0.2.1/30 dev veth-as2-as4
sudo ip netns exec R2BGP ip link set veth-as2-as4 up

sudo ip netns exec R3BGP ip link set lo up
sudo ip netns exec R3BGP ip addr add 10.0.1.2/30 dev veth-as3-as2
sudo ip netns exec R3BGP ip link set veth-as3-as2 up

sudo ip netns exec R4BGP ip link set lo up
sudo ip netns exec R4BGP ip addr add 10.0.2.2/30 dev veth-as4-as2
sudo ip netns exec R4BGP ip link set veth-as4-as2 up

# Forwarding — R2BGP is the transit AS, needs this to relay R1<->R3 traffic
for r in R1BGP R2BGP R3BGP R4BGP; do
  sudo ip netns exec $r sysctl -w net.ipv4.ip_forward=1
done

# Blackhole routes — zebra's own static-route install path is broken on this
# build (see bgp-lab-environment.md), so these are installed directly via
# the kernel and do NOT persist across reboot. Must be reissued every boot.
sudo ip netns exec R3BGP ip route add blackhole 172.16.30.0/24
sudo ip netns exec R4BGP ip route add blackhole 172.16.30.0/25

# /var/run/frr/<router> is tmpfs — recreate every boot
for r in R1BGP R2BGP R3BGP R4BGP; do
  sudo mkdir -p /var/run/frr/$r
  sudo chown -R frr:frrvty /var/run/frr/$r
done

# mgmtd, then zebra, then bgpd — in that order, for every router
for r in R1BGP R2BGP R3BGP R4BGP; do
  sudo ip netns exec $r /usr/lib/frr/mgmtd -d -N $r --vty_socket /var/run/frr/$r \
    --log file:/var/log/frr/$r-mgmtd.log
done
sleep 2

for r in R1BGP R2BGP R3BGP R4BGP; do
  sudo ip netns exec $r /usr/lib/frr/zebra -d -N $r --vty_socket /var/run/frr/$r \
    -f /etc/frr/$r/zebra.conf --log file:/var/log/frr/$r-zebra.log
done
sleep 2

for r in R1BGP R2BGP R3BGP R4BGP; do
  sudo ip netns exec $r /usr/lib/frr/bgpd -d -N $r --vty_socket /var/run/frr/$r \
    -f /etc/frr/$r/bgpd.conf --log file:/var/log/frr/$r-bgpd.log
done
sleep 5

echo "-- bgpd check --"
for r in R1BGP R2BGP R3BGP R4BGP; do sudo ip netns exec $r pgrep -a bgpd; done
