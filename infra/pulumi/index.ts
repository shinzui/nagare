import * as pulumi from "@pulumi/pulumi";
import * as gcp from "@pulumi/gcp";
import { NagarePerimeter } from "./src/components/NagarePerimeter";
import { buildSshCommand } from "./src/outputs";

const cfg = new pulumi.Config();
const gcpCfg = new pulumi.Config("gcp");

const gcpProject = gcpCfg.require("project");
const region = gcpCfg.require("region");
const zone = gcpCfg.require("zone");

// Project-specific config with defaults so a fresh checkout previews
// without extra setup. Local variable names are suffixed `Cfg` so they
// never collide with the exported stack-output names below (a Pulumi
// stack output is named after its exported binding, so the exports must
// literally be `baseDomain`, `instanceName`, etc.).
const instanceNameCfg = cfg.get("instanceName") ?? "nagare-01";
const machineTypeCfg = cfg.get("machineType") ?? "e2-standard-2";
const dataDiskSizeGbCfg = cfg.getNumber("dataDiskSizeGb") ?? 100;
const baseDomainCfg = cfg.get("baseDomain") ?? "apps.example.com";
const artifactRegistryIdCfg = cfg.get("artifactRegistryId") ?? "nagare";
const backupBucketNameCfg = cfg.get("backupBucket") ?? `${gcpProject}-nagare-backups`;
const imageBucketNameCfg = cfg.require("imageBucket"); // set in Pulumi.<context>.yaml

// IP-10: EP-3 writes this after building+registering the NixOS image.
// `get` (not `require`) so the VM is simply omitted until it is set.
const imageSelfLink = cfg.get("nagareImageSelfLink");

// MasterPlan 11 / EP-56: opt-in for the standing Google Cloud CDN load
// balancer. Default false so existing `pulumi up` runs are byte-for-byte
// unchanged and the billable load balancer is never created implicitly.
const enableCdnCfg = cfg.getBoolean("enableCdn") ?? false;

// EP-99: GCP-level deletion protection for the VM. Default true — the API then
// refuses to delete the instance at all. The platform's *intended* rebuild path
// (docs/runbooks/disaster-recovery.md, "Replace the VM onto the fixed image")
// changes `nagareImageSelfLink`, which forces a Pulumi replacement, so the
// deliberate procedure is:
//   pulumi -C infra/pulumi config set vmDeletionProtection false && just infra-up
//   <perform the rebuild>
//   pulumi -C infra/pulumi config set vmDeletionProtection true  && just infra-up
// Two commands, not a code edit, and the default stays fail-closed.
const vmDeletionProtectionCfg = cfg.getBoolean("vmDeletionProtection") ?? true;

// EP-99: boot-disk geometry, previously hardcoded in NagareInstance.
// pd-balanced is the sensible default for a fresh stack. CAUTION: GCE cannot
// convert a boot disk's type in place, so changing `bootDiskType` against a
// live VM forces an INSTANCE REPLACEMENT. A stack whose VM is already running
// on another type should pin it (`pulumi config set bootDiskType pd-standard`)
// until a deliberate rebuild is being performed.
const bootDiskSizeGbCfg = cfg.getNumber("bootDiskSizeGb") ?? 100;
const bootDiskTypeCfg = cfg.get("bootDiskType") ?? "pd-balanced";

// EP-63: codify the GCP service APIs the topology needs. On a brand-new project
// these may be off; declaring them here makes `pulumi up` self-enable them, and
// the `dependsOn` below sequences enablement before any resource that uses them.
// `scripts/enable-apis.sh` enables the identical set out-of-band before the very
// first `pulumi up` (solving the EP-2 bootstrap chicken-and-egg); these resources
// make every subsequent `pulumi up` self-asserting. disableDependentServices /
// disableOnDestroy are false so `pulumi destroy` never turns an API off under
// another workload in a shared project (MasterPlan 12, EP-63 Decision Log).
const requiredApis = [
    "compute.googleapis.com",
    "dns.googleapis.com",
    "storage.googleapis.com",
    "artifactregistry.googleapis.com",
    "iam.googleapis.com",
    "servicenetworking.googleapis.com",
];
const apiServices = requiredApis.map(
    (api) =>
        new gcp.projects.Service(`api-${api.split(".")[0]}`, {
            project: gcpProject,
            service: api,
            disableDependentServices: false,
            disableOnDestroy: false,
        }),
);

const perimeter = new NagarePerimeter(
    "nagare",
    {
        gcpProject,
        region,
        zone,
        instanceName: instanceNameCfg,
        machineType: machineTypeCfg,
        dataDiskSizeGb: dataDiskSizeGbCfg,
        baseDomain: baseDomainCfg,
        artifactRegistryId: artifactRegistryIdCfg,
        backupBucketName: backupBucketNameCfg,
        imageBucketName: imageBucketNameCfg,
        imageSelfLink,
        enableCdn: enableCdnCfg,
        vmDeletionProtection: vmDeletionProtectionCfg,
        bootDiskSizeGb: bootDiskSizeGbCfg,
        bootDiskType: bootDiskTypeCfg,
    },
    { dependsOn: apiServices },
);

// Integration Point 1 — the nine exact stack-output names. The exported
// binding name *is* the stack-output name, so do not rename any of these
// without updating the MasterPlan and the consuming plans (EP-3/4/6/7).
export const publicIp = perimeter.publicIp;
export const baseDomain = baseDomainCfg;
export const instanceName = perimeter.instanceName;
export const serviceAccountEmail = perimeter.serviceAccountEmail;
export const dataDiskName = perimeter.dataDiskName;
export const dnsZoneName = perimeter.dnsZoneName;
export const artifactRegistry = perimeter.artifactRegistry;
export const backupBucket = perimeter.backupBucket;
export const sshCommand = buildSshCommand(perimeter.instanceName, zone, gcpProject);

// MasterPlan 11 / EP-56 — Integration Point 2. The exported binding name *is*
// the stack-output name, so these are the exact `cdnGlobalIp` /
// `cdnBackendService` / `cdnUrlMap` contract EP-58 reads via
// `pulumi stack output`. Do not rename without updating the MasterPlan and EP-58.
export const cdnGlobalIp = perimeter.cdnGlobalIp;
export const cdnBackendService = perimeter.cdnBackendService;
export const cdnUrlMap = perimeter.cdnUrlMap;
