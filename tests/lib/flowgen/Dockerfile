# Client image: FRR (BGP to ToR) + python (flowgen) + net tooling.
# Build:  docker build -t maglev/client:latest tests/lib/flowgen/
FROM quay.io/frrouting/frr:9.1.0

# FRR base is alpine; add python3 + tooling for flowgen and inspection.
RUN apk add --no-cache python3 tcpdump iproute2 iputils bash conntrack-tools

COPY flowgen.py /opt/flowgen/flowgen.py
RUN chmod +x /opt/flowgen/flowgen.py

CMD ["sleep", "infinity"]
