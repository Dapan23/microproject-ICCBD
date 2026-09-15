# microproject-ICCBD

Comparison between the **Flannel** and **Cilium** CNIs (both in L3 routing, no overlay) on a Kubernetes cluster. The comparison has been carried out on network performance (TCP throughput and retransmissions, UDP throughput and loss, with iperf3) and security (L3/L4 and L7 Network Policy, which Cilium offers and Flannel doesn't).

The performance comparison relies on iperf3 alone, with no direct measurement of CPU overhead. With multiple VMs on the same host, this measurement would capture hypervisor contention more than the CNI itself. The drop in TCP retransmissions and the iptables/eBPF argument specifically remains a clue that the retransmission difference may be caused by the difference in how each CNI processes packets in the kernel (eBPF vs. iptables/netfilter), not just VM/hypervisor contention.

## Infrastructure

- 3 VMs (Multipass, QEMU driver): 1 master (`master-node`), 2 workers (`worker-01`, `worker-02`).
- No Docker on the host: it would share the kernel (and therefore routing, iptables, network namespaces) between the nodes and the host, skewing the measurements. With separate VMs, each node has its own isolated kernel.
- Kubernetes v1.30 via kubeadm, containerd as runtime (see `provisioning/install-k8s.sh`).

## Phase 1: Flannel

### VXLAN bug, switch to host-gw

The initial setup used Flannel with the VXLAN backend. Traffic between nodes was 100% blocked (ICMP packet loss, failed ARP). I turned off TX checksum offloading on flannel.1 and allowed all forwarded traffic, probably a VirtIO/KVM bug was breaking UDP tunnels, but it didn't work. This is a sign of incompatibility between the hypervisor and Flannel's VXLAN frames. Switched to `host-gw` (direct L3, no overlay) and connectivity came back immediately.

Between the Flannel and Cilium tests, the cluster was fully reset, to avoid contaminating kernel state between the two cases.

In `host-gw`, each node adds a static route to the others' pod subnet, using the remote node's IP as gateway, this works with no extra configuration because the nodes are on the same L2 subnet.

### Benchmark

`iperf3-server`/`iperf3-client` pods (`manifests/baseline/iperf3-*.yaml`), pinned to `worker-01`/`worker-02`:

| Test | Bitrate (sender) | Bitrate (receiver) | Note |
|------|-------------------|---------------------|------|
| TCP  | 1.30 Gbits/sec    | 1.29 Gbits/sec      | 1175 retransmissions over 10s |
| UDP  | 1.00 Gbits/sec    | 0.53 Gbits/sec      | 47% datagrams lost (`-b 1G`) |

Data can be found in `benchmark_results/flannel_tcp.txt` and `benchmark_results/flannel_udp.txt`.

Flannel has no NetworkPolicy engine, this means no isolation possible between pods, at any level.

## Phase 2: Cilium (native routing)

### Setup

Cilium 1.19.6, `routingMode: native`, no overlay, to stay comparable with Flannel's host-gw. `kubeProxyReplacement: false` because kube-proxy stays active as in the Flannel setup, so the CNI is the only variable that changes. Helm values can be found in `manifests/cilium/values-native-routing.yaml`.

Main difference is that Cilium hooks into kernel eBPF with O(1) hash maps for routing and policy, instead of the O(n) iptables chain used by Flannel/kube-proxy. This is the reason why we can observe a drop in retransmissions in the TCP benchmark.

### Benchmark

Same pods, same nodes, same iperf3 command as Flannel:

| Test | Bitrate (sender) | Bitrate (receiver) | Note |
|------|-------------------|---------------------|------|
| TCP  | 1.30 Gbits/sec    | 1.30 Gbits/sec      | **198 retransmissions over 10s** |
| UDP  | 1.00 Gbits/sec    | 0.54 Gbits/sec      | 46% datagrams lost (`-b 1G`) |

Data can be found in `benchmark_results/cilium_tcp.txt` and `benchmark_results/cilium_udp.txt`.

### Comparison table

| Metric | Flannel host-gw | Cilium native routing | Delta |
|---------|------------------|-------------------------|-------|
| TCP throughput | 1.30 Gbit/s | 1.30 Gbit/s | unchanged (VM limit) |
| **TCP retransmissions** | **1175** | **198** | **-83%** |
| UDP throughput (RX) | 0.53 Gbit/s | 0.54 Gbit/s | ~unchanged |
| UDP packet loss | 47% | 46% | ~unchanged |

We observe identical throughput the bottleneck is the VMs' virtual network, not the CNI. The real difference is in **TCP retransmissions: -83% with Cilium**, consistent with a more efficient datapath but not a direct CPU measurement. UDP loss under stress stays unchanged (47% vs 46%).

### Network Policy (L3/L4 and L7)

Cilium applies an eBPF-based NetworkPolicy engine, Flannel doesn't. Two static examples in `manifests/network-policies/`:

- `l3-l4-policy.yaml`: IP/port isolation, restricts `iperf3-server` to only `iperf3-client` on 5201/TCP.
- `l7-http-policy.yaml`: HTTP-level isolation via Cilium's Envoy proxy, filters by method and path, impossible at L3/L4.

### Network Policy demo

The enforcement test I actually ran is Cilium's official "Star Wars" demo (`sw_l3_l4_l7_policy.yaml`), observed with **Hubble**. The `CiliumNetworkPolicy` it applies isn't L7-only, it combines all three layers in one rule: `fromEndpoints: matchLabels: org: empire` restricts the source identity (L3), `toPorts: port: "80", protocol: TCP` restricts the port/protocol (L4), and `rules.http: method: POST, path: /v1/request-landing` restricts the HTTP method and path (L7).

Scenario: the "Rebel" pod (`xwing`, label `org: alliance`) tries to reach `deathstar` the same way the authorized "Empire" pod does, without authorization:

- The attack is dropped immediately at the kernel level (eBPF, visible with `hubble observe --verdict DROPPED`): the TCP SYN is discarded before reaching the `deathstar` pod's namespace.
- On the "Rebel" side, `curl` ends with **exit code 28** (timeout), not an explicit refusal: proof that the drop happens on the datapath, not at the destination pod.

What this actually shows is L3 (identity-based) enforcement: the Rebel pod doesn't match `fromEndpoints`, so Cilium drops it before ever checking the port (L4) or the HTTP method/path (L7). To exercise the L7 rule for real, an authorized "Empire" pod would need to try a disallowed method or path (e.g. `GET` instead of `POST`), a test I didn't run here. Still, this is Zero-Trust micro-segmentation impossible with Flannel alone, which has no NetworkPolicy engine at any layer.

## Study limitations

- **No direct CPU measurement**: the drop in TCP retransmissions (-83%) and the iptables O(n) vs eBPF O(1) argument remain an indirect clue, not a quantification.
- UDP loss under stress (46-47%) is the same for both CNIs, attributed to a hardware limit (vCPU interrupts) never isolated experimentally.
- Benchmark run with a single iperf3 stream per test is not representative of multi-connection loads.

## Conclusions

For this exact test on raw throughput, under equal conditions, Cilium and Flannel are equivalent: the bottleneck is the VMs' virtual network, not the CNI. The real difference is in **TCP retransmissions (-83% with Cilium)**, a clue pointing to a more efficient datapath, not a direct CPU measurement.

On features, Flannel has no NetworkPolicy: no isolation. Cilium can isolate at L3/L4 and L7, but the Deathstar demo only exercises L3 identity-based enforcement; the L4/L7 rules in the same policy are described here, not demonstrated.

For this use case, the choice between Flannel and Cilium comes down more to security and observability than to raw performance.
