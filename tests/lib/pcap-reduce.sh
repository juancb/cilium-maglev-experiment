#!/bin/sh
# Runs INSIDE a node container. Reduce a tests/05 capture (tcpdump -i any) to one line per
# (second, src, dst) with a packet count, so only a few MB cross the 9p mount:
#   <sec>.0 <src>.<sport> > <dst>.<dport> <count>
# Keeps client->VIP packets (ingress-node evidence) and the ingress node's forward packets
# to the backend pod (client-src under DSR, node-IP-src under SNAT). analyze-rehoming.py
# understands the trailing count.
# usage: pcap-reduce.sh <pcap> <client-src-ip> <vip>
pcap="$1"; src="$2"; vip="$3"
tcpdump -nn -tt -r "$pcap" \
  "(src $src and dst $vip) or ((src $src or src net 10.10.0.0/24) and dst net 10.244.0.0/16)" 2>/dev/null \
| awk '{ split($1, a, "."); d = $7; sub(/:$/, "", d); k = a[1] ".0 " $5 " > " d; c[k]++ }
       END { for (k in c) print k, c[k] }'
