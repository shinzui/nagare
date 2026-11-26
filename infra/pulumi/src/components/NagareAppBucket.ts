import * as pulumi from "@pulumi/pulumi";
import * as gcp from "@pulumi/gcp";
import { shouldDeclareResource } from "../resourceDeclarations";
import { workloadIdentityPrincipal } from "./NagareWorkloadIdentity";

// EP-284 (MasterPlan 39): one application's object bucket on a cloud context, and
// one Google service account per granted workload.
//
// The bucket is private by construction: uniform bucket-level access, enforced
// public access prevention, versioning off, and one Delete rule per declared expiry.
// It is protected and never force-destroyed: a dropped or retired bucket keeps its
// objects (ADR 22).
//
// Each grant's account holds exactly one role on this bucket: Storage Object User for
// read-write, Storage Object Viewer for read-only. Its only member of
// roles/iam.workloadIdentityUser is the workload's one pool subject, so only that
// Kubernetes service account's token reaches it. A signing grant also holds
// roles/iam.serviceAccountTokenCreator on itself, which carries
// iam.serviceAccounts.signBlob for V4 signed URLs; a custom role with only that
// permission is not visible to IAM in the update that creates it
// (NagareDelegatedDeployer.ts). Nothing is granted at project level and no key is
// created: the pod's projected token is its only credential.
//
// A retired bucket keeps every resource and disables its accounts, which refuses
// every credential at once.

export type BucketAccess = "read-write" | "read-only";

export interface AppBucketGrant {
    subject: string;       // system:serviceaccount:NS:nagare-wl-WORKLOAD
    accountId: string;     // the service account ID nagarectl derived, at most 30 characters
    access: BucketAccess;
    signUrls: boolean;
}

export interface AppBucketExpiry {
    prefix: string;
    afterDays: number;
}

export interface AppBucketEntry {
    name: string;          // the declared bucket name, a DNS label
    bucket: string;        // the Google bucket name nagarectl derived
    retired: boolean;
    expire: AppBucketExpiry[];
    grants: AppBucketGrant[];
}

export interface NagareAppBucketArgs {
    gcpProject: string;
    region: string;
    projectNumber: pulumi.Input<string>;
    poolId: string;
    entry: AppBucketEntry;
}

export const bucketAccessRoles: Record<BucketAccess, string> = {
    "read-write": "roles/storage.objectUser",
    "read-only": "roles/storage.objectViewer",
};

// The component's Pulumi name, as the catalog's `nagare-bucket-{bucket}`.
export function appBucketComponentName(name: string): string {
    return `nagare-bucket-${name}`;
}

export class NagareAppBucket extends pulumi.ComponentResource {
    public readonly bucket: gcp.storage.Bucket | undefined;
    public readonly accountEmails: pulumi.Output<string>[];

    constructor(name: string, args: NagareAppBucketArgs, opts?: pulumi.ComponentResourceOptions) {
        super("nagare:env:NagareAppBucket", name, {}, opts);
        const entry = args.entry;
        const declare = (type: string, suffix: string) => shouldDeclareResource(type, `${name}-${suffix}`);

        this.bucket = declare("gcp:storage/bucket:Bucket", "bucket") ? new gcp.storage.Bucket(`${name}-bucket`, {
            project: args.gcpProject,
            name: entry.bucket,
            location: args.region,
            uniformBucketLevelAccess: true,
            publicAccessPrevention: "enforced",
            versioning: { enabled: false },
            lifecycleRules: entry.expire.map((rule) => ({
                action: { type: "Delete" },
                condition: { age: rule.afterDays, matchesPrefixes: [rule.prefix] },
            })),
        }, { parent: this, protect: true }) : undefined;
        const bucketName = this.bucket?.name ?? pulumi.output(entry.bucket);

        this.accountEmails = entry.grants.map((grant) => {
            const grantName = `${name}-${grant.accountId}`;
            const declareGrant = (type: string, suffix: string) => shouldDeclareResource(type, `${grantName}-${suffix}`);
            const account = declareGrant("gcp:serviceaccount/account:Account", "sa") ? new gcp.serviceaccount.Account(`${grantName}-sa`, {
                project: args.gcpProject,
                accountId: grant.accountId,
                displayName: `Nagare bucket ${entry.name} ${grant.access}`,
                description: grant.subject,
                disabled: entry.retired,
            }, { parent: this }) : undefined;
            const email = account?.email ?? pulumi.output(`${grant.accountId}@${args.gcpProject}.iam.gserviceaccount.com`);
            const accountName = account?.name ?? pulumi.interpolate`projects/${args.gcpProject}/serviceAccounts/${email}`;
            const member = pulumi.interpolate`serviceAccount:${email}`;

            if (declareGrant("gcp:storage/bucketIAMMember:BucketIAMMember", "access")) new gcp.storage.BucketIAMMember(`${grantName}-access`, {
                bucket: bucketName,
                role: bucketAccessRoles[grant.access],
                member,
            }, { parent: this });
            if (declareGrant("gcp:serviceaccount/iAMMember:IAMMember", "federation")) new gcp.serviceaccount.IAMMember(`${grantName}-federation`, {
                serviceAccountId: accountName,
                role: "roles/iam.workloadIdentityUser",
                member: pulumi.output(args.projectNumber).apply((number) => workloadIdentityPrincipal(number, args.poolId, grant.subject)),
            }, { parent: this });
            if (grant.signUrls && declareGrant("gcp:serviceaccount/iAMMember:IAMMember", "signer")) new gcp.serviceaccount.IAMMember(`${grantName}-signer`, {
                serviceAccountId: accountName,
                role: "roles/iam.serviceAccountTokenCreator",
                member,
            }, { parent: this });
            return email;
        });

        this.registerOutputs({ bucket: bucketName, accountEmails: this.accountEmails });
    }
}

const dnsLabel = /^[a-z0-9]([-a-z0-9]{0,28}[a-z0-9])?$/;
const googleBucketName = /^[a-z0-9][-a-z0-9_]{1,61}[a-z0-9]$/;
const accountIdPattern = /^[a-z][-a-z0-9]{4,28}[a-z0-9]$/;
// google.subject is at most 127 bytes.
const subjectPattern = /^system:serviceaccount:[a-z0-9]([-a-z0-9]*[a-z0-9])?:nagare-wl-[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;

// The derived config: a JSON list of buckets with distinct names, Google names and
// account IDs. Each grant is one account, so an account ID is never repeated, even
// across buckets.
export function parseAppBuckets(raw: string | undefined): AppBucketEntry[] {
    if (raw === undefined || raw.trim() === "") return [];
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) throw new Error("nagare:appBuckets must be a JSON list");
    const entries = parsed.map((value): AppBucketEntry => {
        const entry = value as Record<string, unknown>;
        if (entry === null || typeof entry !== "object"
            || typeof entry.name !== "string" || !dnsLabel.test(entry.name)
            || typeof entry.bucket !== "string" || !googleBucketName.test(entry.bucket) || entry.bucket.startsWith("goog")
            || typeof entry.retired !== "boolean" || !Array.isArray(entry.expire) || !Array.isArray(entry.grants)) {
            throw new Error("each nagare:appBuckets entry needs a DNS-label name, a Google bucket name, retired, expire and grants");
        }
        const expire = entry.expire.map((value): AppBucketExpiry => {
            const rule = value as Record<string, unknown>;
            if (rule === null || typeof rule !== "object" || typeof rule.prefix !== "string" || rule.prefix === ""
                || typeof rule.afterDays !== "number" || !Number.isInteger(rule.afterDays) || rule.afterDays < 1) {
                throw new Error(`nagare:appBuckets ${entry.name}: an expiry rule needs a prefix and a positive whole afterDays`);
            }
            return { prefix: rule.prefix, afterDays: rule.afterDays };
        });
        const grants = entry.grants.map((value): AppBucketGrant => {
            const grant = value as Record<string, unknown>;
            if (grant === null || typeof grant !== "object"
                || typeof grant.subject !== "string" || !subjectPattern.test(grant.subject) || grant.subject.length > 127
                || typeof grant.accountId !== "string" || !accountIdPattern.test(grant.accountId)
                || (grant.access !== "read-write" && grant.access !== "read-only")
                || typeof grant.signUrls !== "boolean") {
                throw new Error(`nagare:appBuckets ${entry.name}: a grant needs a nagare-wl subject, an account ID, an access and signUrls`);
            }
            return { subject: grant.subject, accountId: grant.accountId, access: grant.access, signUrls: grant.signUrls };
        });
        const subjects = grants.map((grant) => grant.subject);
        if (new Set(subjects).size !== subjects.length) throw new Error(`nagare:appBuckets ${entry.name} grants one subject twice`);
        return { name: entry.name, bucket: entry.bucket, retired: entry.retired, expire, grants };
    });
    for (const [label, values] of [
        ["name", entries.map((entry) => entry.name)],
        ["bucket", entries.map((entry) => entry.bucket)],
        ["accountId", entries.flatMap((entry) => entry.grants.map((grant) => grant.accountId))],
    ] as [string, string[]][]) {
        if (new Set(values).size !== values.length) throw new Error(`nagare:appBuckets repeats a ${label}`);
    }
    return entries;
}
