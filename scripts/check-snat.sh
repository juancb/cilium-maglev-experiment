#!/usr/bin/env python3
"""
Check if Cilium applies SNAT for VIP flows by opening a connection from the client
and checking the source IP that the echo pod sees.
"""
import subprocess, time

CLIENT = "clab-maglev-clos-client"
VIP = "192.0.2.10"
PORT = "8080"

# Open a connection and read the pod greeting
cmd = ["docker", "exec", CLIENT, "bash", "-c",
       f"exec 3<>/dev/tcp/{VIP}/{PORT}; head -c 50 <&3"]
result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
print("Pod greeting:", result.stdout.strip())

# Now check what the echo pod's conntrack shows for the connection
# (to see if the source IP is the client IP or SNATed)
KC = ["docker", "exec", "-e", "KUBECONFIG=/etc/rancher/k3s/k3s.yaml",
      "clab-maglev-clos-node1", "k3s", "kubectl"]

# Get the cilium pod on node3 (where pods run)
pods_cmd = KC + ["-n", "kube-system", "get", "pods", "-l", "k8s-app=cilium",
                  "--field-selector", "spec.nodeName=node3",
                  "-o", "jsonpath={.items[0].metadata.name}"]
pod3 = subprocess.run(pods_cmd, capture_output=True, text=True, timeout=5).stdout.strip()
print(f"Cilium pod on node3: {pod3}")

# Check the ct table on node3 for connections to the echo pods
ct_cmd = KC + ["-n", "kube-system", "exec", pod3, "--",
               "cilium-dbg", "bpf", "ct", "list", "global"]
result = subprocess.run(ct_cmd, capture_output=True, text=True, timeout=10)
lines = [l for l in result.stdout.split('\n') if '10.244.0' in l]
print(f"CT entries to echo pods on node3 (first 5):")
for l in lines[:5]:
    print(" ", l)
