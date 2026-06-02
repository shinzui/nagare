import * as pulumi from "@pulumi/pulumi";
import { NagarePerimeter } from "./src/components/NagarePerimeter";
import { buildSshCommand } from "./src/outputs";

const cfg = new pulumi.Config();
const gcpCfg = new pulumi.Config("gcp");

const gcpProject = gcpCfg.require("project");   // "tan-nb-exp"
const region = gcpCfg.require("region");        // "us-west1"
const zone = gcpCfg.require("zone");            // "us-west1-a"

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
const imageBucketNameCfg = cfg.require("imageBucket"); // set in Pulumi.dev.yaml

// IP-10: EP-3 writes this after building+registering the NixOS image.
// `get` (not `require`) so the VM is simply omitted until it is set.
const imageSelfLink = cfg.get("nagareImageSelfLink");

const perimeter = new NagarePerimeter("nagare", {
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
});

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
