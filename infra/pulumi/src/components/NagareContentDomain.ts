import * as pulumi from "@pulumi/pulumi";
import * as gcp from "@pulumi/gcp";
import { shouldDeclareResource } from "../resourceDeclarations";

// EP-285 (MasterPlan 39): one content domain a context lists in
// NAGARE_CONTENT_DOMAINS, served by one application worker as `*.D` and `D`.
//
// The context owns the domain's Cloud DNS zone, separate from the base
// domain's: the operator delegates the registrable domain to the zone's name
// servers at the registrar. The wildcard and apex records point at the
// address the base domain's wildcard uses, the VM's regional static IP, so
// Kourier receives the requests.
//
// The VM account gets roles/dns.admin on this zone only, so cert-manager's
// DNS-01 solver can write the `_acme-challenge` record for the wildcard
// certificate. The solver finds the zone by listing the project's zones,
// which the perimeter's project-level roles/dns.reader already allows.
//
// A tunnel context creates none of this: its ingress rules are fixed to the
// base zone (ADR 34), so nagarectl never derives the config there.

export interface NagareContentDomainArgs {
    gcpProject: string;
    domain: string;                       // "content.example.org", no trailing dot
    vmAddress: pulumi.Input<string>;      // the address the base wildcard record uses
    serviceAccountEmail: pulumi.Input<string>;
}

// The slug the catalog and nagarectl use in names: the domain with `.` as `-`.
export function contentDomainSlug(domain: string): string {
    return domain.replace(/\./g, "-");
}

// The Cloud DNS zone name, fixed so `nagarectl domains check` can describe it.
export function contentDomainZoneName(domain: string): string {
    return `nagare-content-${contentDomainSlug(domain)}`;
}

// The derived config: a comma-separated list of lower-case DNS names, each
// with at least two labels and distinct slugs. nagarectl has already refused a
// domain that touches the base domain.
export function parseContentDomains(raw: string | undefined): string[] {
    if (raw === undefined || raw.trim() === "") return [];
    const domains = raw.split(",").map((value) => value.trim()).filter((value) => value !== "");
    const label = /^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$/;
    for (const domain of domains) {
        const labels = domain.split(".");
        if (labels.length < 2 || !labels.every((part) => label.test(part)) || domain.length > 48) {
            throw new Error(`nagare:contentDomains has an invalid domain: ${domain}`);
        }
    }
    const slugs = domains.map(contentDomainSlug);
    if (new Set(slugs).size !== slugs.length) throw new Error("nagare:contentDomains repeats a domain");
    return domains;
}

export class NagareContentDomain extends pulumi.ComponentResource {
    public readonly zoneName: pulumi.Output<string>;
    public readonly nameServers: pulumi.Output<string[]>;

    constructor(name: string, args: NagareContentDomainArgs, opts?: pulumi.ComponentResourceOptions) {
        super("nagare:env:NagareContentDomain", name, {}, opts);
        const dnsName = `${args.domain}.`;
        const declare = (type: string, suffix: string) => shouldDeclareResource(type, `${name}-${suffix}`);

        const zone = declare("gcp:dns/managedZone:ManagedZone", "zone") ? new gcp.dns.ManagedZone(`${name}-zone`, {
            name: contentDomainZoneName(args.domain),
            dnsName,
            description: "Nagare content domain zone",
        }, { parent: this }) : undefined;
        const zoneName = zone?.name ?? pulumi.output(contentDomainZoneName(args.domain));

        if (declare("gcp:dns/dnsManagedZoneIamMember:DnsManagedZoneIamMember", "iam-dns-zone")) new gcp.dns.DnsManagedZoneIamMember(`${name}-iam-dns-zone`, {
            project: args.gcpProject,
            managedZone: zoneName,
            role: "roles/dns.admin",
            member: pulumi.interpolate`serviceAccount:${args.serviceAccountEmail}`,
        }, { parent: this });
        if (declare("gcp:dns/recordSet:RecordSet", "wildcard")) new gcp.dns.RecordSet(`${name}-wildcard`, {
            managedZone: zoneName,
            name: `*.${dnsName}`,
            type: "A",
            ttl: 300,
            rrdatas: [args.vmAddress],
        }, { parent: this });
        if (declare("gcp:dns/recordSet:RecordSet", "apex")) new gcp.dns.RecordSet(`${name}-apex`, {
            managedZone: zoneName,
            name: dnsName,
            type: "A",
            ttl: 300,
            rrdatas: [args.vmAddress],
        }, { parent: this });

        this.zoneName = zoneName;
        this.nameServers = zone?.nameServers ?? pulumi.output([]);
        this.registerOutputs({ zoneName: this.zoneName, nameServers: this.nameServers });
    }
}
