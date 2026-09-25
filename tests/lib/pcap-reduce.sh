#!/bin/sh
# Runs INSIDE a node container. Reduce a tests/05 capture (tcpdump -i any) to one line per
# (second, direction, src, dst) with a packet count, so only a few MB cross the 9p mount:
#   <sec>.0 <In|Out> <src>.<sport> > <dst>.<dport> <count>
# Keeps client->VIP packets (ingress-node evidence: "In" on the ingress node) and forward
# packets to a backend pod (client-src under DSR, node-IP-src under SNAT; the source port
# is preserved). The direction matters: the node that FORWARDS to a pod sees the packet
# "Out", the node that HOSTS the pod sees the same packet "In", and only the former says
# which backend that ingress node chose. analyze-rehoming.py understands the format.
# usage: pcap-reduce.sh <pcap> <client-src-ip> <vip>
pcap="$1"; src="$2"; vip="$3"
tcpdump -nn -tt -r "$pcap" \
  "(src $src and dst $vip) or ((src $src or src net 10.10.0.0/24) and dst net 10.244.0.0/16)" 2>/dev/null \
| awk '{ split($1, a, "."); d = $7; sub(/:$/, "", d); k = a[1] ".0 " $3 " " $5 " > " d; c[k]++ }
       END { for (k in c) print k, c[k] }'
