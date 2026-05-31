#!/usr/bin/env bash
# Configure BGP on the SONiC ToR by starting bgpd and applying config via vtysh.
# SONiC skips bgpd if BGP_NEIGHBOR is absent from config_db (sonic-cfggen drops it).
# We bypass config_db entirely: start bgpd directly and push the config via vtysh.
# See docs/ADDRESSING.md for all addresses/ASNs.
set -uo pipefail
TOR="clab-maglev-clos-tor"

echo "=== starting bgpd on ToR ==="
# Create a minimal bgpd.conf so bgpd starts cleanly
docker exec "$TOR" bash -c 'cat > /etc/frr/bgpd.conf <<EO
frr version 10.3
frr defaults datacenter
hostname tor
log stdout
EO
chown frr:frr /etc/frr/bgpd.conf'

# Enable bgpd in the FRR daemons file and start it via supervisord
docker exec "$TOR" bash -c 'sed -i "s/^bgpd=no/bgpd=yes/" /etc/frr/daemons'
docker exec "$TOR" supervisorctl start bgpd 2>/dev/null || \
  docker exec "$TOR" bash -c '/usr/lib/frr/bgpd -A 127.0.0.1 -d'

echo "waiting for bgpd to accept connections..."
for _ in $(seq 1 15); do
  docker exec "$TOR" vtysh -c "show bgp summary" &>/dev/null && break
  sleep 2
done

echo "=== applying BGP config via vtysh ==="
# ToR AS65000. eBGP peers: client (65100), spine1/2/3 (65001/2/3).
# Interfaces: eth1=client (10.0.0.1/31), eth2=spine1 (10.1.1.0/31),
#             eth3=spine2 (10.1.1.2/31), eth4=spine3 (10.1.1.4/31).
# Apply addresses first (zebra already running), then BGP.
docker exec "$TOR" vtysh << 'VTYSH'
configure terminal
interface lo
 ip address 10.255.0.0/32
!
interface eth1
 ip address 10.0.0.1/31
!
interface eth2
 ip address 10.1.1.0/31
!
interface eth3
 ip address 10.1.1.2/31
!
interface eth4
 ip address 10.1.1.4/31
!
router bgp 65000
 bgp router-id 10.255.0.0
 bgp bestpath as-path multipath-relax
 no bgp ebgp-requires-policy
 neighbor 10.0.0.0 remote-as 65100
 neighbor 10.1.1.1 remote-as 65001
 neighbor 10.1.1.3 remote-as 65002
 neighbor 10.1.1.5 remote-as 65003
 !
 address-family ipv4 unicast
  redistribute connected
  maximum-paths 8
  neighbor 10.0.0.0 activate
  neighbor 10.1.1.1 activate
  neighbor 10.1.1.3 activate
  neighbor 10.1.1.5 activate
 exit-address-family
!
end
write memory
VTYSH

echo "=== verifying ==="
sleep 3
docker exec "$TOR" vtysh -c "show bgp summary" 2>/dev/null
docker exec "$TOR" vtysh -c "show interface eth2" 2>/dev/null | grep -E "inet|up|down" | head -5
