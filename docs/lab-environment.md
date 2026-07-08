# Lab Environment

Ubuntu VM running FRRouting 10.6.1, four routers simulated as Linux network
namespaces (R1-R4) connected via veth pairs, each router running its own
zebra/ospfd instance via FRR's `-N <pathspace>` option.

## Operational issue 1: saved config not loading on daemon restart

**Symptom:** after a fresh zebra/ospfd launch from `start-lab.sh`,
`show ip ospf neighbor` returned "OSPF is not enabled in vrf default" despite
a complete, valid `router ospf` block already saved in `/etc/frr/<router>/ospfd.conf`.

**Diagnosis:** `-N <pathspace>` alone did not reliably auto-load the config
from its default expected path on this FRR build.

**Fix:** launch every daemon with an explicit `-f /etc/frr/<router>/<daemon>.conf`
rather than relying on `-N`'s implicit path lookup.

## Operational issue 2: OSPF adjacency stalls at 2-Way on virtual point-to-point links

**Symptom:** R2-R3 and R2-R4 adjacencies stuck at `2-Way/DROther`, never
reaching Full, despite confirmed IP connectivity and zero packet loss.

**Diagnosis:** `show ip ospf interface <if>` showed `Network Type BROADCAST`.
OSPF requires DR/BDR election to complete before non-DR/BDR neighbors reach
Full on broadcast-type interfaces (RFC 2328 S10.4). These veth links only
ever have two possible participants, so the election serves no purpose and
can stall on virtual interfaces.

**Fix:** `ip ospf network point-to-point` on both ends of every router-to-router
interface, skipping DR/BDR election entirely.

**Note:** R1-R2 happened not to exhibit the stall, but the same fix was applied
there too for topology-wide consistency — a real dedicated point-to-point
research link wouldn't run DR/BDR election either.

## Verified baseline (no authentication)

R1's routing table confirms full end-to-end reachability learned purely via
OSPF: `3.3.3.3/32` and `4.4.4.4/32` both reachable via `10.0.12.2` at cost 20,
despite R1 having no direct link to R3 or R4. This is the no-auth control
group that Phase 2 (MD5) and Phase 3 (SHA-256) results are compared against.
