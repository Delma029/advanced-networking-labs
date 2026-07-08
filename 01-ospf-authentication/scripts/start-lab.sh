#!/bin/bash
set -e

for r in R1 R2 R3 R4; do
  sudo ip netns add $r
done

sudo ip link add veth-r1-r2 type veth peer name veth-r2-r1
sudo ip link add veth-r2-r3 type veth peer name veth-r3-r2
sudo ip link add veth-r2-r4 type veth peer name veth-r4-r2
sudo ip link set veth-r1-r2 netns R1
sudo ip link set veth-r2-r1 netns R2
sudo ip link set veth-r2-r3 netns R2
sudo ip link set veth-r3-r2 netns R3
sudo ip link set veth-r2-r4 netns R2
sudo ip link set veth-r4-r2 netns R4

sudo ip netns exec R1 ip link set lo up
sudo ip netns exec R1 ip addr add 1.1.1.1/32 dev lo
sudo ip netns exec R1 ip addr add 10.0.12.1/30 dev veth-r1-r2
sudo ip netns exec R1 ip link set veth-r1-r2 up

sudo ip netns exec R2 ip link set lo up
sudo ip netns exec R2 ip addr add 2.2.2.2/32 dev lo
sudo ip netns exec R2 ip addr add 10.0.12.2/30 dev veth-r2-r1
sudo ip netns exec R2 ip link set veth-r2-r1 up
sudo ip netns exec R2 ip addr add 10.0.23.1/30 dev veth-r2-r3
sudo ip netns exec R2 ip link set veth-r2-r3 up
sudo ip netns exec R2 ip addr add 10.0.24.1/30 dev veth-r2-r4
sudo ip netns exec R2 ip link set veth-r2-r4 up

sudo ip netns exec R3 ip link set lo up
sudo ip netns exec R3 ip addr add 3.3.3.3/32 dev lo
sudo ip netns exec R3 ip addr add 10.0.23.2/30 dev veth-r3-r2
sudo ip netns exec R3 ip link set veth-r3-r2 up

sudo ip netns exec R4 ip link set lo up
sudo ip netns exec R4 ip addr add 4.4.4.4/32 dev lo
sudo ip netns exec R4 ip addr add 10.0.24.2/30 dev veth-r4-r2
sudo ip netns exec R4 ip link set veth-r4-r2 up

for r in R1 R2 R3 R4; do
  sudo ip netns exec $r sysctl -w net.ipv4.ip_forward=1
done

for r in R1 R2 R3 R4; do
  sudo mkdir -p /var/run/frr/$r
  sudo chown -R frr:frrvty /var/run/frr/$r
done

for r in R1 R2 R3 R4; do
  sudo ip netns exec $r /usr/lib/frr/zebra -d -N $r --vty_socket /var/run/frr/$r \
    --log file:/var/log/frr/$r-zebra.log
done
sleep 2
echo "-- zebra check --"
for r in R1 R2 R3 R4; do sudo ip netns exec $r pgrep -a zebra; done

for r in R1 R2 R3 R4; do
  sudo ip netns exec $r /usr/lib/frr/ospfd -d -N $r --vty_socket /var/run/frr/$r \
    --log file:/var/log/frr/$r-ospfd.log
done
sleep 2
echo "-- ospfd check --"
for r in R1 R2 R3 R4; do sudo ip netns exec $r pgrep -a ospfd; done
