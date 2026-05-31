# Kubernetes node image: k3s (server/agent) + host bird2 + tooling.
# Build:  docker build -t maglev/k3s-bird:latest nodes/
#
# Runs as a privileged containerlab node. k3s is invoked by `make up` (not at build time) so
# server/agent role + cross-node join can be coordinated after the fabric converges.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        bird2 iproute2 iptables ipset kmod \
        curl ca-certificates jq conntrack ethtool tcpdump iputils-ping \
        procps less vim-tiny \
    && rm -rf /var/lib/apt/lists/*

# k3s binary (pin a recent stable; override with --build-arg K3S_VERSION=...)
ARG K3S_VERSION=v1.31.4+k3s1
RUN curl -fsSL "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s" \
        -o /usr/local/bin/k3s && chmod +x /usr/local/bin/k3s \
    && ln -s /usr/local/bin/k3s /usr/local/bin/kubectl \
    && ln -s /usr/local/bin/k3s /usr/local/bin/crictl

# cilium CLI + helm for in-node install convenience
RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash \
    && CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt) \
    && curl -fsSL "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz" \
        | tar xz -C /usr/local/bin cilium

RUN mkdir -p /etc/bird /run/bird
CMD ["sleep", "infinity"]
