import * as pulumi from "@pulumi/pulumi";
import * as gcp from "@pulumi/gcp";
import { NagareNetwork } from "./NagareNetwork";
import { NagareInstance } from "./NagareInstance";
import { NagareCdn } from "./NagareCdn";

export interface NagarePerimeterArgs {
    gcpProject: string;
    region: string;
    zone: string;
    instanceName: string;       // "nagare-01"
    machineType: string;        // "e2-standard-2"
    dataDiskSizeGb: number;     // 100
    baseDomain: string;         // "apps.example.com"
    artifactRegistryId: string; // "nagare"
    backupBucketName: string;
    imageBucketName: string;
    /** Present only after EP-3 sets Pulumi config `nagareImageSelfLink`.
     *  When undefined, the VM is not declared. */
    imageSelfLink?: string;
    /** MasterPlan 11 / EP-56: opt-in for the standing Google Cloud CDN load
     *  balancer (default false; billable, so never created implicitly). */
    enableCdn: boolean;
    /** EP-99: GCP-level deletion protection on the VM (default true). */
    vmDeletionProtection: boolean;
    /** EP-99: boot disk size in GB (default 100). */
    bootDiskSizeGb: number;
    /** EP-99: boot disk type (default pd-balanced). Changing this against a
     *  live VM forces an instance replacement. */
    bootDiskType: string;
}

export class NagarePerimeter extends pulumi.ComponentResource {
    public readonly publicIp: pulumi.Output<string>;
    public readonly serviceAccountEmail: pulumi.Output<string>;
    public readonly dataDiskName: pulumi.Output<string>;
    public readonly dnsZoneName: pulumi.Output<string>;
    public readonly artifactRegistry: pulumi.Output<string>;
    public readonly backupBucket: pulumi.Output<string>;
    public readonly instanceName: pulumi.Output<string>;
    // MasterPlan 11 / EP-56 — Integration Point 2. Read by EP-58 via
    // `pulumi stack output`. When the CDN is disabled (flag off or no VM), these
    // carry a clear sentinel so the output is well-typed but obviously absent.
    public readonly cdnGlobalIp: pulumi.Output<string>;
    public readonly cdnBackendService: pulumi.Output<string>;
    public readonly cdnUrlMap: pulumi.Output<string>;

    constructor(name: string, args: NagarePerimeterArgs, opts?: pulumi.ComponentResourceOptions) {
        super("nagare:env:NagarePerimeter", name, {}, opts);

        const net = new NagareNetwork(`${name}-network`, { region: args.region }, { parent: this });

        // Static external IPv4 address, regional. Reserving it means the
        // VM keeps the same public IP across rebuilds, so the wildcard DNS
        // record stays valid.
        const address = new gcp.compute.Address(`${name}-ip`, {
            region: args.region,
        }, { parent: this });

        // Persistent data disk (IP-3). pd-balanced is the cost/perf
        // sweet spot; 100 GB default. EP-3 attaches and mounts it at
        // /var/lib/nagare.
        // EP-99 `protect: true`: every byte of app data lives on this disk, so
        // any plan that would delete it fails with "resource ... is protected".
        // This is a Pulumi *state* option — no cloud API call, no diff — and it
        // is deliberately reversible: `pulumi state unprotect '<urn>'` (find the
        // URN with `pulumi stack --show-urns`), then apply. The next `pulumi up`
        // re-asserts protection, because it is declared here.
        const dataDisk = new gcp.compute.Disk(`${name}-data`, {
            zone: args.zone,
            type: "pd-balanced",
            size: args.dataDiskSizeGb,
        }, { parent: this, protect: true });

        // Daily whole-disk snapshot of the data disk (keep 7). This is the
        // coarse, beneath-the-apps restore point; app-level backups (EP-7 /
        // managed DBs) remain the primary mechanism. KEEP_AUTO_SNAPSHOTS means
        // snapshots outlive the disk — which is exactly the disaster this
        // guards against. Incremental snapshots of a ~100 GB pd-balanced disk
        // cost on the order of $1-3/month. startTime is UTC and must be on the
        // hour; 08:00 UTC is around midnight Pacific, off-peak.
        const dataSnapshots = new gcp.compute.ResourcePolicy(`${name}-data-snapshots`, {
            region: args.region,
            snapshotSchedulePolicy: {
                schedule: { dailySchedule: { daysInCycle: 1, startTime: "08:00" } },
                retentionPolicy: { maxRetentionDays: 7, onSourceDiskDelete: "KEEP_AUTO_SNAPSHOTS" },
            },
        }, { parent: this });
        new gcp.compute.DiskResourcePolicyAttachment(`${name}-data-snapshot-attach`, {
            name: dataSnapshots.name,
            disk: dataDisk.name,
            zone: args.zone,
        }, { parent: this });

        // Dedicated service account (IP-2). Lowercase `serviceaccount`
        // module per the spec correction.
        const sa = new gcp.serviceaccount.Account(`${name}-sa`, {
            accountId: "nagare-node",
            displayName: "Nagare node/workload service account",
        }, { parent: this });

        // Non-authoritative IAM members (spec correction: never use the
        // authoritative *IAMBinding/*IAMPolicy variants on the shared
        // project). roles/artifactregistry.writer lets nagarectl (EP-6) push
        // images. The DNS rights the cert-manager DNS-01 solver needs are
        // granted below, next to the zone they are scoped to.
        const saMember = pulumi.interpolate`serviceAccount:${sa.email}`;
        new gcp.projects.IAMMember(`${name}-iam-ar`, {
            project: args.gcpProject,
            role: "roles/artifactregistry.writer",
            member: saMember,
        }, { parent: this });

        // GCS bucket for backups (IP for EP-7). Uniform bucket-level
        // access means IAM alone controls access (no per-object ACLs).
        //
        // EP-99 hardening. The node service account keeps objectAdmin here
        // (the backup jobs need it), which means a compromised node could
        // delete its own backups. Versioning turns every delete or overwrite
        // into a *noncurrent version* that can be restored, and the lifecycle
        // rule expires those after 30 days — long enough to notice a malicious
        // or accidental wipe, short enough that cost stays under a dollar a
        // month at this platform's scale (roughly one extra generation of the
        // backup set). `protect: true` additionally stops Pulumi itself from
        // ever deleting the bucket; unprotect deliberately with
        // `pulumi state unprotect '<urn>'` if it must go.
        const backupBucket = new gcp.storage.Bucket(`${name}-backups`, {
            name: args.backupBucketName,
            location: args.region.toUpperCase(), // GCS uses upper-case region names
            uniformBucketLevelAccess: true,
            forceDestroy: false,
            versioning: { enabled: true },
            lifecycleRules: [{
                action: { type: "Delete" },
                condition: { daysSinceNoncurrentTime: 30 },
            }],
            publicAccessPrevention: "enforced",
        }, { parent: this, protect: true });

        // Grant the service account object-admin on the backup bucket only
        // (scoped, non-authoritative). EP-7's backup jobs write here.
        new gcp.storage.BucketIAMMember(`${name}-backups-iam`, {
            bucket: backupBucket.name,
            role: "roles/storage.objectAdmin",
            member: saMember,
        }, { parent: this });

        // GCS bucket for image staging (IP-10). EP-3's
        // scripts/upload-images.sh uploads the NixOS *.raw.tar.gz here
        // before registering it as a GCE image.
        new gcp.storage.Bucket(`${name}-images`, {
            name: args.imageBucketName,
            location: args.region.toUpperCase(),
            uniformBucketLevelAccess: true,
            forceDestroy: false,
            // EP-99: nothing here should ever be world-readable. Not protected —
            // image staging is reproducible from `just host-image`.
            publicAccessPrevention: "enforced",
        }, { parent: this });

        // Cloud DNS managed zone for the apps domain (IP-4). dnsName must
        // be a fully-qualified domain with a trailing dot.
        const dnsName = `${args.baseDomain}.`;
        const dnsZone = new gcp.dns.ManagedZone(`${name}-zone`, {
            dnsName,
            description: "Nagare apps wildcard zone",
        }, { parent: this });

        // EP-99: DNS rights for the cert-manager (EP-4) Let's Encrypt DNS-01
        // solver, scoped as tightly as the solver actually allows. This
        // replaces a project-wide roles/dns.admin grant, which let a
        // compromised node rewrite every zone in the project.
        //
        // Two grants are needed, not one. The ClusterIssuer template
        // cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl sets no
        // `hostedZoneName`, so the solver first LISTS the project's managed
        // zones (dns.managedZones.list — a project-level permission) to find
        // the zone matching the domain, then writes the _acme-challenge TXT
        // record in it (covered by the zone-scoped admin). roles/dns.reader is
        // read-only. Tightening further by setting `hostedZoneName` in the
        // template and dropping dns.reader is an optional follow-up.
        new gcp.dns.DnsManagedZoneIamMember(`${name}-iam-dns-zone`, {
            project: args.gcpProject,
            managedZone: dnsZone.name,
            role: "roles/dns.admin",
            member: saMember,
        }, { parent: this });
        new gcp.projects.IAMMember(`${name}-iam-dns-read`, {
            project: args.gcpProject,
            role: "roles/dns.reader",
            member: saMember,
        }, { parent: this });

        // Wildcard A record: *.apps.example.com -> publicIp. ttl in
        // seconds; rrdatas is the list of answer IPs.
        new gcp.dns.RecordSet(`${name}-wildcard`, {
            managedZone: dnsZone.name,
            name: pulumi.interpolate`*.${dnsName}`,
            type: "A",
            ttl: 300,
            rrdatas: [address.address],
        }, { parent: this });

        // Artifact Registry Docker repository (IP for EP-6). Location is
        // the region; repositoryId is the short name "nagare".
        const registry = new gcp.artifactregistry.Repository(`${name}-registry`, {
            location: args.region,
            repositoryId: args.artifactRegistryId,
            format: "DOCKER",
        }, { parent: this });

        // The VM exists only once EP-3 has produced the boot image.
        let instance: NagareInstance | undefined;
        if (args.imageSelfLink) {
            instance = new NagareInstance(args.instanceName, {
                zone: args.zone,
                machineType: args.machineType,
                imageSelfLink: args.imageSelfLink,
                subnetId: net.subnet.id,
                publicIp: address.address,
                dataDiskId: dataDisk.id,
                serviceAccountEmail: sa.email,
                deletionProtection: args.vmDeletionProtection,
                bootDiskSizeGb: args.bootDiskSizeGb,
                bootDiskType: args.bootDiskType,
            }, { parent: this });
        }

        // MasterPlan 11 / EP-56: the standing Google Cloud CDN load balancer.
        // Instantiated only when the operator opts in (the flag is billable) AND
        // the VM exists (the backend needs an origin to point at). When either is
        // absent, the three outputs carry a clear disabled sentinel that EP-58
        // treats as "no Google CDN provisioned".
        const CDN_DISABLED = "(cdn disabled)";
        if (args.enableCdn && instance) {
            const cdn = new NagareCdn(`${name}-cdn`, {
                gcpProject: args.gcpProject,
                region: args.region,
                zone: args.zone,
                baseDomain: args.baseDomain,
                instanceSelfLink: instance.instance.selfLink,
                network: net.network.id,
                publicIp: address.address,
            }, { parent: this });
            this.cdnGlobalIp = cdn.cdnGlobalIp;
            this.cdnBackendService = cdn.cdnBackendService;
            this.cdnUrlMap = cdn.cdnUrlMap;
        } else {
            this.cdnGlobalIp = pulumi.output(CDN_DISABLED);
            this.cdnBackendService = pulumi.output(CDN_DISABLED);
            this.cdnUrlMap = pulumi.output(CDN_DISABLED);
        }

        this.publicIp = address.address;
        this.serviceAccountEmail = sa.email;
        this.dataDiskName = dataDisk.name;
        this.dnsZoneName = dnsZone.name;
        // Stable Docker registry hostname/path EP-6 pushes to.
        this.artifactRegistry = pulumi.interpolate`${args.region}-docker.pkg.dev/${args.gcpProject}/${args.artifactRegistryId}`;
        this.backupBucket = backupBucket.name;
        // instanceName is known even before the VM resource exists, so
        // EP-3 can read it from config-time inputs; if the VM exists we
        // use its real name for fidelity.
        this.instanceName = instance ? instance.instance.name : pulumi.output(args.instanceName);

        this.registerOutputs({
            publicIp: this.publicIp,
            serviceAccountEmail: this.serviceAccountEmail,
            dataDiskName: this.dataDiskName,
            dnsZoneName: this.dnsZoneName,
            artifactRegistry: this.artifactRegistry,
            backupBucket: this.backupBucket,
            instanceName: this.instanceName,
            cdnGlobalIp: this.cdnGlobalIp,
            cdnBackendService: this.cdnBackendService,
            cdnUrlMap: this.cdnUrlMap,
        });
    }
}
