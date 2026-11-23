import * as pulumi from "@pulumi/pulumi";
import * as gcp from "@pulumi/gcp";

// EP-235 M2 (MasterPlan 31): the cloud identity of the lifecycle event worker
// `nagare-events`.
//
// The admin API reader cannot be reused: it stays read-only and reads only
// the recorded-state objects (EP-196). The worker gets its own account,
// bound only on buckets, never on the project:
//
//  - the state bucket's inventory prefix, read-only: Storage Object Viewer
//    for the objects and Storage Bucket Viewer for the bucket's metadata,
//    both under one condition. The worker reads the inventory head, journal
//    and accepted native bytes but never writes them;
//  - the state bucket's lifecycle prefix beside the inventory
//    (`<inventory parent>/lifecycle/v1/`, as `Nagare.Events.Target` derives
//    it), read-write: Storage Object User under a condition naming that
//    prefix only. Cloud Storage checks `storage.objects.create` for a new
//    object and additionally `storage.objects.delete` to overwrite an
//    existing one, including the generation-conditioned replacement of the
//    feed head, so a create-only role cannot replace the head. Object User
//    also allows update, restore and move, still only beneath the prefix;
//  - the context's backup bucket, read-only and unconditioned: Storage Object
//    Viewer for receipt discovery and verification, and Storage Bucket Viewer
//    for the ownership check. No write, update or delete.
//
// `storage.objects.list` and `storage.buckets.get` are checked against the
// bucket (`projects/_/buckets/<bucket>`), not an object, so the inventory
// condition also admits the bucket itself, as the delegated deployer's does
// (proved by the EP-248 D6 native check). The worker can therefore list the
// names of every object in the state bucket, but read only the inventory and
// the lifecycle feed, and write only the feed. The feed condition names no
// bucket, so its role's list permission never applies; the feed never lists.
// No predefined role grants `storage.buckets.get` more narrowly than Bucket
// Viewer, which adds only bucket listing in the project.
//
// Predefined roles, as the delegated deployer's: a custom role created in the
// same update as its binding was not yet visible to IAM (EP-248 D6), and a
// custom role ID is per project, so two contexts in one project would clash.
//
// No stack output, as the delegated deployer has none: nagarectl derives the
// email from the account ID, and a new output would change every existing
// stack's preview. No key is created here: a key in Pulumi state would put
// operator secret material in this repository's state (ADR 13).

export interface NagareLifecycleWorkerArgs {
    enabled: boolean;
    gcpProject: string;
    accountId: string;          // "nagare-events"
    stateBucket: string;        // "<project>-nagare-pulumi-state"
    inventoryPrefix: string;    // "nagare/<context>/inventory"
    backupBucket: pulumi.Input<string>; // "<project>-nagare-backups"
}

// The predefined roles the worker's grants bind.
export const lifecycleWorkerRoles = {
    objectReader: "roles/storage.objectViewer",
    bucketReader: "roles/storage.bucketViewer",
    feedWriter: "roles/storage.objectUser",
};

export class NagareLifecycleWorker extends pulumi.ComponentResource {
    public readonly email: pulumi.Output<string>;

    constructor(name: string, args: NagareLifecycleWorkerArgs, opts?: pulumi.ComponentResourceOptions) {
        super("nagare:env:NagareLifecycleWorker", name, {}, opts);
        if (!args.enabled) {
            this.email = pulumi.output("");
            this.registerOutputs({});
            return;
        }

        const account = new gcp.serviceaccount.Account(`${name}-sa`, {
            project: args.gcpProject,
            accountId: args.accountId,
            displayName: "Nagare lifecycle event worker",
        }, { parent: this });
        const member = pulumi.interpolate`serviceAccount:${account.email}`;

        const inventory = {
            title: "nagare-lifecycle-inventory-read",
            description: "The context's inventory objects, and the bucket for listing and its metadata.",
            expression: lifecycleInventoryReadCondition(args.stateBucket, args.inventoryPrefix),
        };
        new gcp.storage.BucketIAMMember(`${name}-inventory`, {
            bucket: args.stateBucket,
            role: lifecycleWorkerRoles.objectReader,
            member,
            condition: inventory,
        }, { parent: this });
        new gcp.storage.BucketIAMMember(`${name}-inventory-bucket`, {
            bucket: args.stateBucket,
            role: lifecycleWorkerRoles.bucketReader,
            member,
            condition: inventory,
        }, { parent: this });
        new gcp.storage.BucketIAMMember(`${name}-feed`, {
            bucket: args.stateBucket,
            role: lifecycleWorkerRoles.feedWriter,
            member,
            condition: {
                title: "nagare-lifecycle-feed-write",
                description: "The context's lifecycle feed objects only.",
                expression: lifecycleFeedWriteCondition(args.stateBucket, args.inventoryPrefix),
            },
        }, { parent: this });
        new gcp.storage.BucketIAMMember(`${name}-backups`, {
            bucket: args.backupBucket,
            role: lifecycleWorkerRoles.objectReader,
            member,
        }, { parent: this });
        new gcp.storage.BucketIAMMember(`${name}-backups-bucket`, {
            bucket: args.backupBucket,
            role: lifecycleWorkerRoles.bucketReader,
            member,
        }, { parent: this });

        this.email = account.email;
        this.registerOutputs({ email: this.email });
    }
}

// The feed's prefix beside an inventory prefix, as `Nagare.Events.Target`'s
// feedLocation derives it: a trailing `/inventory` becomes `/lifecycle/v1`,
// any other prefix gets `-lifecycle/v1` appended.
export function lifecyclePrefix(inventoryPrefix: string): string {
    const trimmed = inventoryPrefix.replace(/\/+$/, "");
    if (trimmed === "inventory") return "lifecycle/v1";
    return trimmed.endsWith("/inventory")
        ? `${trimmed.slice(0, -"/inventory".length)}/lifecycle/v1`
        : `${trimmed}-lifecycle/v1`;
}

function objectRoot(bucket: string, prefix: string): string {
    return `projects/_/buckets/${bucket}/objects/${prefix.replace(/^\/+|\/+$/g, "")}/`;
}

// Object names are projects/_/buckets/<bucket>/objects/<name>; the bucket's
// own name is projects/_/buckets/<bucket>.
export function lifecycleInventoryReadCondition(bucket: string, inventoryPrefix: string): string {
    return [
        `resource.name == "projects/_/buckets/${bucket}"`,
        `resource.name.startsWith("${objectRoot(bucket, inventoryPrefix)}")`,
    ].join(" || ");
}

export function lifecycleFeedWriteCondition(bucket: string, inventoryPrefix: string): string {
    return `resource.name.startsWith("${objectRoot(bucket, lifecyclePrefix(inventoryPrefix))}")`;
}
