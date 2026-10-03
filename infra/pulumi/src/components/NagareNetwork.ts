import * as pulumi from "@pulumi/pulumi";
import * as gcp from "@pulumi/gcp";
import { shouldDeclareResource } from "../resourceDeclarations";

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
    public readonly network: gcp.compute.Network | undefined;
    public readonly subnet: gcp.compute.Subnetwork | undefined;

    constructor(name: string, args: NagareNetworkArgs, opts?: pulumi.ComponentResourceOptions) {
        super("nagare:net:NagareNetwork", name, {}, opts);

        // Custom-mode VPC: we declare the single subnet ourselves rather
        // than letting GCP auto-create one per region.
        this.network = shouldDeclareResource("gcp:compute/network:Network", `${name}-net`) ? new gcp.compute.Network(`${name}-net`, {
            autoCreateSubnetworks: false,
        }, { parent: this }) : undefined;

        this.subnet = shouldDeclareResource("gcp:compute/subnetwork:Subnetwork", `${name}-subnet`) ? new gcp.compute.Subnetwork(`${name}-subnet`, {
            ipCidrRange: SUBNET_CIDR,
            region: args.region,
            network: this.network!.id,
        }, { parent: this }) : undefined;

        // Public HTTPS/HTTP ingress for Kourier (the Knative ingress
        // gateway, backed by Envoy, installed by EP-4). On a single k3s
        // node, k3s's ServiceLB binds host ports 80 and 443 to Kourier's
        // LoadBalancer Service, so the world must be able to reach 80/443.
        shouldDeclareResource("gcp:compute/firewall:Firewall", `${name}-fw-web`) ? new gcp.compute.Firewall(`${name}-fw-web`, {
            network: this.network!.id,
            direction: "INGRESS",
            sourceRanges: ["0.0.0.0/0"],
            allows: [{ protocol: "tcp", ports: ["80", "443"] }],
        }, { parent: this }) : undefined;

        // SSH only from the IAP range. See IAP_SOURCE_RANGE comment.
        shouldDeclareResource("gcp:compute/firewall:Firewall", `${name}-fw-iap-ssh`) ? new gcp.compute.Firewall(`${name}-fw-iap-ssh`, {
            network: this.network!.id,
            direction: "INGRESS",
            sourceRanges: [IAP_SOURCE_RANGE],
            allows: [{ protocol: "tcp", ports: ["22"] }],
        }, { parent: this }) : undefined;

        // Google load-balancer health-check / proxy source ranges (MasterPlan
        // 11 / EP-56). A Google global external Application Load Balancer probes
        // and proxies to the origin from 130.211.0.0/22 and 35.191.0.0/16; this
        // rule admits them on the backend ports. It is intentionally NOT gated
        // behind `nagare:enableCdn`: it only widens which source ranges may
        // reach already-open ports (fw-web opens 80/443 to 0.0.0.0/0), so it is
        // free and harmless when the CDN is off, and it documents the dependency
        // and survives any future tightening of fw-web.
        shouldDeclareResource("gcp:compute/firewall:Firewall", `${name}-fw-lb-health`) ? new gcp.compute.Firewall(`${name}-fw-lb-health`, {
            network: this.network!.id,
            direction: "INGRESS",
            sourceRanges: ["130.211.0.0/22", "35.191.0.0/16"],
            allows: [{ protocol: "tcp", ports: ["80", "443"] }],
        }, { parent: this }) : undefined;

        // Tailscale's direct-connection port. Tailscale (configured by
        // EP-3) is a mesh VPN; udp/41641 is the port its WireGuard data
        // plane prefers for direct peer connections. Allowing it from
        // anywhere lets Tailscale establish direct (non-relayed) links;
        // if blocked, Tailscale still works via its relays (DERP), so
        // this is an optimization, not a hard requirement.
        shouldDeclareResource("gcp:compute/firewall:Firewall", `${name}-fw-tailscale`) ? new gcp.compute.Firewall(`${name}-fw-tailscale`, {
            network: this.network!.id,
            direction: "INGRESS",
            sourceRanges: ["0.0.0.0/0"],
            allows: [{ protocol: "udp", ports: ["41641"] }],
        }, { parent: this }) : undefined;

        this.registerOutputs({});
    }
}
