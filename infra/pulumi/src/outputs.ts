import * as pulumi from "@pulumi/pulumi";

/**
 * Integration Point 1 (MasterPlan): the exact set of stack outputs EP-2
 * publishes. EP-3, EP-4, EP-6, and EP-7 read these by name with
 * `pulumi stack output <name>`. Renaming any field here is a cross-plan
 * breaking change and must be coordinated via the MasterPlan.
 */
export interface StackOutputs {
    publicIp: pulumi.Output<string>;
    sshCommand: pulumi.Output<string>;
    baseDomain: pulumi.Output<string>;
    instanceName: pulumi.Output<string>;
    serviceAccountEmail: pulumi.Output<string>;
    dataDiskName: pulumi.Output<string>;
    dnsZoneName: pulumi.Output<string>;
    artifactRegistry: pulumi.Output<string>;
    backupBucket: pulumi.Output<string>;
    // MasterPlan 11 Integration Point 2 (EP-56) — the standing Google Cloud CDN
    // load balancer's anycast IP, CDN-enabled backend service name, and URL map
    // name. Read by EP-58 to write per-hostname DNS and per-path cache rules.
    // Carry the sentinel "(cdn disabled)" when `nagare:enableCdn` is off.
    cdnGlobalIp: pulumi.Output<string>;
    cdnBackendService: pulumi.Output<string>;
    cdnUrlMap: pulumi.Output<string>;
}

/**
 * Build a ready-to-paste SSH command. Port 22 is reachable only through
 * the GCP Identity-Aware Proxy (IAP) tunnel (see the firewall rules), so
 * the command always tunnels through IAP and targets the project/zone we
 * pin everywhere. `instanceName` is e.g. "nagare-01".
 */
export function buildSshCommand(
    instanceName: pulumi.Input<string>,
    zone: string,
    gcpProject: string,
): pulumi.Output<string> {
    return pulumi.output(instanceName).apply(
        (name) =>
            `gcloud compute ssh ${name} ` +
            `--project=${gcpProject} --zone=${zone} --tunnel-through-iap`,
    );
}
