import * as pulumi from "@pulumi/pulumi";
import * as gcp from "@pulumi/gcp";

// EP-196 (MasterPlan 28): the read-only identity of the context's admin API.
//
// The node account cannot be reused: it already writes Artifact Registry and
// the backup bucket. This dedicated account can read exactly the objects the
// recorded-state reader needs in the Pulumi state bucket: the context's
// inventory format.json, head.json and scopes/. It cannot list the bucket,
// write anything, or read reviews/, native/, objects/, journal/ (which can
// hold private reviewed bytes) or any Pulumi state. A second, unconditional
// grant reads only the bucket's own metadata, for the ownership check; an
// object-name condition cannot match the bucket itself.
//
// No key is created here: a key in Pulumi state would put operator secret
// material in this repository's state (ADR 13). The operator creates the
// key with `gcloud iam service-accounts keys create` into the private
// operator repository's sops material (docs/runbooks/admin-api-reader.md).
//
// The expected owner of the bucket is the project's number, exported for
// the admin API's deployment, so the server needs no project lookup
// permission.

export interface NagareAdminApiReaderArgs {
    enabled: boolean;
    gcpProject: string;
    accountId: string;          // "nagare-admin-api"
    stateBucket: string;        // "<project>-nagare-pulumi-state"
    inventoryPrefix: string;    // "nagare/<context>/inventory"
}

export class NagareAdminApiReader extends pulumi.ComponentResource {
    public readonly enabled: pulumi.Output<boolean>;
    public readonly email: pulumi.Output<string>;
    public readonly projectNumber: pulumi.Output<string>;

    constructor(name: string, args: NagareAdminApiReaderArgs, opts?: pulumi.ComponentResourceOptions) {
        super("nagare:env:NagareAdminApiReader", name, {}, opts);
        this.enabled = pulumi.output(args.enabled);
        if (!args.enabled) {
            this.email = pulumi.output("");
            this.projectNumber = pulumi.output("");
            this.registerOutputs({ enabled: this.enabled });
            return;
        }

        const account = new gcp.serviceaccount.Account(`${name}-sa`, {
            accountId: args.accountId,
            displayName: "Nagare admin API (read-only inventory reader)",
        }, { parent: this });
        const member = pulumi.interpolate`serviceAccount:${account.email}`;

        const objectReader = new gcp.projects.IAMCustomRole(`${name}-object-role`, {
            project: args.gcpProject,
            roleId: "nagareInventoryObjectReader",
            title: "Nagare inventory object reader",
            description: "Read one object; granted only with an exact object-name condition.",
            permissions: ["storage.objects.get"],
        }, { parent: this });
        const bucketReader = new gcp.projects.IAMCustomRole(`${name}-bucket-role`, {
            project: args.gcpProject,
            roleId: "nagareInventoryBucketReader",
            title: "Nagare inventory bucket metadata reader",
            description: "Read a bucket's metadata, for the owning-project check.",
            permissions: ["storage.buckets.get"],
        }, { parent: this });

        new gcp.storage.BucketIAMMember(`${name}-objects`, {
            bucket: args.stateBucket,
            role: objectReader.name,
            member,
            condition: {
                title: "nagare-inventory-recorded-read",
                description: "The context's inventory format, head and scope members only.",
                expression: inventoryReadCondition(args.stateBucket, args.inventoryPrefix),
            },
        }, { parent: this });
        new gcp.storage.BucketIAMMember(`${name}-bucket`, {
            bucket: args.stateBucket,
            role: bucketReader.name,
            member,
        }, { parent: this });

        this.email = account.email;
        this.projectNumber = gcp.organizations.getProjectOutput({ projectId: args.gcpProject }).number;
        this.registerOutputs({ enabled: this.enabled, email: this.email, projectNumber: this.projectNumber });
    }
}

// The IAM condition naming exactly the objects the recorded reader reads,
// including the platform-versions snapshot (EP-236) and nothing else under
// versions/. Object resource names are projects/_/buckets/<bucket>/objects/<name>.
export function inventoryReadCondition(bucket: string, prefix: string): string {
    const root = `projects/_/buckets/${bucket}/objects/${prefix.replace(/\/+$/, "")}`;
    return [
        `resource.name == "${root}/format.json"`,
        `resource.name == "${root}/head.json"`,
        `resource.name == "${root}/versions/latest.json"`,
        `resource.name.startsWith("${root}/scopes/")`,
    ].join(" || ");
}
