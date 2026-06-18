/* XDP: drop foreign-unicast (PACKET_OTHERHOST) frames on the vmnet NIC.
 *
 * socket_vmnet floods every unicast frame to all guest VMs and does no per-VM MAC
 * filtering, so on a kube-proxy-free Cilium cluster EVERY node's tc/eBPF datapath
 * accepts a LoadBalancer VIP frame addressed to one node's MAC -> duplicate SYN-ACKs
 * -> host TCP handshake fails. Dropping foreign-MAC unicast at XDP (which runs BEFORE
 * the tc ingress hook where Cilium lives) means only the node whose MAC actually
 * matches processes the frame -> single responder -> host->VIP works.
 *
 * Broadcast/multicast (ARP, NDP, the L2-announce gratuitous ARP) are always passed.
 * The local MAC is injected at compile time via -DM0..-DM5.
 */
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <bpf/bpf_helpers.h>

char _license[] SEC("license") = "GPL";

SEC("xdp")
int xdp_drop_foreign(struct xdp_md *ctx)
{
	void *data = (void *)(long)ctx->data;
	void *data_end = (void *)(long)ctx->data_end;
	struct ethhdr *eth = data;

	if ((void *)(eth + 1) > data_end)
		return XDP_PASS;

	unsigned char *d = eth->h_dest;

	/* broadcast / multicast: LSB of first octet set -> always pass */
	if (d[0] & 1)
		return XDP_PASS;

	unsigned char me[6] = { M0, M1, M2, M3, M4, M5 };
#pragma unroll
	for (int i = 0; i < 6; i++)
		if (d[i] != me[i])
			return XDP_DROP; /* foreign unicast (PACKET_OTHERHOST) */

	return XDP_PASS; /* unicast addressed to this node */
}
