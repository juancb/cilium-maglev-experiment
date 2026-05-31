# Addressing & ASN plan (single source of truth)

Every config file in this repo references the values below. If you change one, grep for the
old value and update all references.

## ASNs (all private, eBGP everywhere)

| Device        | ASN    | Role                                   |
|---------------|--------|----------------------------------------|
| client        | 65100  | traffic source, advertises its loopback|
| tor (SONiC)   | 65000  | 3-way ECMP across spines; **CH knob**  |
| spine1/2/3    | 65001 / 65002 / 65003 | FRR fabric                |
| leaf1/2       | 65011 / 65012         | FRR fabric                |
| node1/2/3 bird| 65021 / 65022 / 65023 | host BGP (2 uplinks)      |
| node1/2/3 cilium | 65031 / 65032 / 65033 | Cilium BGP → local bird|

## Loopbacks / router-ids

| Device  | Loopback / router-id |
|---------|----------------------|
| tor     | 10.255.0.0           |
| spine1  | 10.255.1.1           |
| spine2  | 10.255.1.2           |
| spine3  | 10.255.1.3           |
| leaf1   | 10.255.2.1           |
| leaf2   | 10.255.2.2           |
| node1   | 10.255.3.1           |
| node2   | 10.255.3.2           |
| node3   | 10.255.3.3           |
| client  | 203.0.113.1          |

## Point-to-point /31 links (lower address listed first = "a" side)

| Link                | Subnet         | a-side (dev=addr)      | b-side (dev=addr)      |
|---------------------|----------------|------------------------|------------------------|
| client ↔ tor        | 10.0.0.0/31    | client=10.0.0.0        | tor=10.0.0.1           |
| tor ↔ spine1        | 10.1.1.0/31    | tor=10.1.1.0           | spine1=10.1.1.1        |
| tor ↔ spine2        | 10.1.1.2/31    | tor=10.1.1.2           | spine2=10.1.1.3        |
| tor ↔ spine3        | 10.1.1.4/31    | tor=10.1.1.4           | spine3=10.1.1.5        |
| spine1 ↔ leaf1      | 10.2.0.0/31    | spine1=10.2.0.0        | leaf1=10.2.0.1         |
| spine1 ↔ leaf2      | 10.2.0.2/31    | spine1=10.2.0.2        | leaf2=10.2.0.3         |
| spine2 ↔ leaf1      | 10.2.0.4/31    | spine2=10.2.0.4        | leaf1=10.2.0.5         |
| spine2 ↔ leaf2      | 10.2.0.6/31    | spine2=10.2.0.6        | leaf2=10.2.0.7         |
| spine3 ↔ leaf1      | 10.2.0.8/31    | spine3=10.2.0.8        | leaf1=10.2.0.9         |
| spine3 ↔ leaf2      | 10.2.0.10/31   | spine3=10.2.0.10       | leaf2=10.2.0.11        |
| leaf1 ↔ node1.fab0  | 10.3.1.0/31    | leaf1=10.3.1.0         | node1.fab0=10.3.1.1    |
| leaf1 ↔ node2.fab0  | 10.3.1.2/31    | leaf1=10.3.1.2         | node2.fab0=10.3.1.3    |
| leaf1 ↔ node3.fab0  | 10.3.1.4/31    | leaf1=10.3.1.4         | node3.fab0=10.3.1.5    |
| leaf2 ↔ node1.fab1  | 10.3.2.0/31    | leaf2=10.3.2.0         | node1.fab1=10.3.2.1    |
| leaf2 ↔ node2.fab1  | 10.3.2.2/31    | leaf2=10.3.2.2         | node2.fab1=10.3.2.3    |
| leaf2 ↔ node3.fab1  | 10.3.2.4/31    | leaf2=10.3.2.4         | node3.fab1=10.3.2.5    |

## Host-facing addresses (advertised into BGP)

| Name                    | Value             | Notes                                   |
|-------------------------|-------------------|-----------------------------------------|
| Service VIP (shared)    | 192.0.2.10/32     | LoadBalancer IP, advertised by all nodes|
| node1/2/3 `public` /32  | 198.51.100.1/2/3  | per-node "public" interface             |
| node1/2/3 `k8s` /32     | 10.10.0.1/2/3     | Kubernetes InternalIP                   |
| node1/2/3 pod CIDR      | 10.244.1/2/3.0/24 | native routing, cluster-pool per node   |
| client source loopback  | 203.0.113.1/32    | flows source from here                  |

## Cilium ↔ bird local session (per node)

- bird listens on `127.0.0.1:179`, `local 127.0.0.1 as 6502x`, `neighbor 127.0.0.1 as 6503x`.
- Cilium agent (hostNetwork) peers `peerAddress: 127.0.0.1`, `peerASN: 6502x`,
  `localASN: 6503x`. eBGP; `ebgpMultihop: 2` set defensively for the loopback session.

## containerlab interface → SONiC port map (ToR)

| clab endpoint | SONiC port  | neighbor |
|---------------|-------------|----------|
| tor:eth1      | Ethernet0   | client   |
| tor:eth2      | Ethernet4   | spine1   |
| tor:eth3      | Ethernet8   | spine2   |
| tor:eth4      | Ethernet12  | spine3   |
