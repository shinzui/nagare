import * as pulumi from "@pulumi/pulumi";
import * as gcp from "@pulumi/gcp";

export interface NagareNetworkArgs {
    region: string;
}

// The subnet's private IP range. /24 is 256 addresses — far more than a
// single-node PaaS needs, and it leaves room without overlapping common
// home/Tailscale ranges.
const SUBNET_CIDR = "10.10.0.0/24";

// GCP Identity-Aware Proxy (IAP) TCP-forwarding source range. SSH is
// allowed *only* from this range so port 22 is never exposed to the
// public internet; reaching it requires an authenticated
// `gcloud compute ssh --tunnel-through-iap` tunnel. This is the exact
// range the reference repo uses.
const IAP_SOURCE_RANGE = "35.235.240.0/20";

export class NagareNetwork extends pulumi.ComponentResource {
    public readonly network: gcp.compute.Network;
    public readonly subnet: gcp.compute.Subnetwork;

    constructor(name: string, args: NagareNetworkArgs, opts?: pulumi.ComponentResourceOptions) {
        super("nagare:net:NagareNetwork", name, {}, opts);

        // Custom-mode VPC: we declare the single subnet ourselves rather
        // than letting GCP auto-create one per region.
        this.network = new gcp.compute.Network(`${name}-net`, {
            autoCreateSubnetworks: false,
        }, { parent: this });

        this.subnet = new gcp.compute.Subnetwork(`${name}-subnet`, {
            ipCidrRange: SUBNET_CIDR,
            region: args.region,
            network: this.network.id,
        }, { parent: this });

        // Public HTTPS/HTTP ingress for Kourier (the Knative ingress
        // gateway, backed by Envoy, installed by EP-4). On a single k3s
        // node, k3s's ServiceLB binds host ports 80 and 443 to Kourier's
        // LoadBalancer Service, so the world must be able to reach 80/443.
        new gcp.compute.Firewall(`${name}-fw-web`, {
            network: this.network.id,
            direction: "INGRESS",
            sourceRanges: ["0.0.0.0/0"],
            allows: [{ protocol: "tcp", ports: ["80", "443"] }],
        }, { parent: this });

        // SSH only from the IAP range. See IAP_SOURCE_RANGE comment.
        new gcp.compute.Firewall(`${name}-fw-iap-ssh`, {
            network: this.network.id,
            direction: "INGRESS",
            sourceRanges: [IAP_SOURCE_RANGE],
            allows: [{ protocol: "tcp", ports: ["22"] }],
        }, { parent: this });

        // Google load-balancer health-check / proxy source ranges (MasterPlan
        // 11 / EP-56). A Google global external Application Load Balancer probes
        // and proxies to the origin from 130.211.0.0/22 and 35.191.0.0/16; this
        // rule admits them on the backend ports. It is intentionally NOT gated
        // behind `nagare:enableCdn`: it only widens which source ranges may
        // reach already-open ports (fw-web opens 80/443 to 0.0.0.0/0), so it is
        // free and harmless when the CDN is off, and it documents the dependency
        // and survives any future tightening of fw-web.
        new gcp.compute.Firewall(`${name}-fw-lb-health`, {
            network: this.network.id,
            direction: "INGRESS",
            sourceRanges: ["130.211.0.0/22", "35.191.0.0/16"],
            allows: [{ protocol: "tcp", ports: ["80", "443"] }],
        }, { parent: this });

        // Tailscale's direct-connection port. Tailscale (configured by
        // EP-3) is a mesh VPN; udp/41641 is the port its WireGuard data
        // plane prefers for direct peer connections. Allowing it from
        // anywhere lets Tailscale establish direct (non-relayed) links;
        // if blocked, Tailscale still works via its relays (DERP), so
        // this is an optimization, not a hard requirement.
        new gcp.compute.Firewall(`${name}-fw-tailscale`, {
            network: this.network.id,
            direction: "INGRESS",
            sourceRanges: ["0.0.0.0/0"],
            allows: [{ protocol: "udp", ports: ["41641"] }],
        }, { parent: this });

        this.registerOutputs({});
    }
}
