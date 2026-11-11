import * as pulumi from "@pulumi/pulumi";
import * as gcp from "@pulumi/gcp";

// EP-248 D6 (MasterPlan 33): the cloud principal of one delegated deployer.
//
// One component per entry of the derived `nagare:delegatedDeployers` config,
// which nagarectl writes from the accepted head's active delegations; it is
// never hand-edited. The deployer gets:
//
//  - its own service account;
//  - an Artifact Registry Docker repository for its delegation's image
//    repository, with that account as a repository-level writer. Artifact
//    Registry grants per repository, so the deployer cannot write the
//    platform's shared repository. The node account keeps its project-level
//    reader/writer access, so the VM pulls these images unchanged;
//  - a custom role on the inventory store's bucket, bound under an IAM
//    condition.
//
// The condition admits objects under `<prefix>/` and the bucket itself.
// Object permissions (get, create, delete) are checked against the object's
// name, so they reach only the context's inventory. `storage.objects.list`
// and `storage.buckets.get` are checked against the bucket
// (`projects/_/buckets/<bucket>`): Cloud Storage does not let an IAM
// condition narrow listing to a prefix (`resource.name` never names an object
// for a list, and the `storage.googleapis.com/objectListPrefix` API attribute
// is supported only in Credential Access Boundaries, not in role bindings).
// So the deployer can list the names and metadata of every object in the
// bucket, including other contexts' Pulumi state object names, but can read,
// write or delete none of them. The store opener needs both bucket-level
// permissions: listing for prefix reads, the bucket's metadata for the
// owning-project check.
//
// Nothing here grants a project-level role. The custom role is a project
// resource, but it is bound only on the bucket. A deleted custom role keeps
// its ID for about 37 days, so re-creating a delegation with the same name
// sooner fails at create until the ID is free.
//
// No key is created here: a key in Pulumi state would put deployer secret
// material in this repository's state (ADR 13). `nagarectl delegation
// credentials` creates the key with the operator's session after the
// project assertion (ADR 9) and writes it only into the private bundle.

export interface DelegatedDeployerEntry {
    name: string;              // the deployer's name (a DNS label)
    accountId: string;         // the service account ID nagarectl derived
    imageRepository: string;   // REGION-docker.pkg.dev/PROJECT/REPO[/...]
    // EP-248 D7: a revoked delegation keeps its resources and disables its
    // account, which refuses every key at once; nothing is retired.
    disabled?: boolean;
}

export interface NagareDelegatedDeployerArgs {
    gcpProject: string;
    region: string;
    platformRepositoryId: string;   // the context's shared repository, never granted
    inventoryBucket: string;        // "<project>-nagare-pulumi-state"
    inventoryPrefix: string;        // "nagare/<context>/inventory"
    deployer: DelegatedDeployerEntry;
}

export const deployerStorePermissions = [
    "storage.buckets.get",
    "storage.objects.create",
    "storage.objects.delete",
    "storage.objects.get",
    "storage.objects.list",
];

export class NagareDelegatedDeployer extends pulumi.ComponentResource {
    public readonly email: pulumi.Output<string>;
    public readonly repository: pulumi.Output<string>;

    constructor(name: string, args: NagareDelegatedDeployerArgs, opts?: pulumi.ComponentResourceOptions) {
        super("nagare:env:NagareDelegatedDeployer", name, {}, opts);
        const deployer = args.deployer;
        const repositoryId = validateDelegatedDeployer(args);

        const account = new gcp.serviceaccount.Account(`${name}-sa`, {
            project: args.gcpProject,
            accountId: deployer.accountId,
            displayName: `Nagare delegated deployer ${deployer.name}`,
            disabled: deployer.disabled === true,
        }, { parent: this });
        const member = pulumi.interpolate`serviceAccount:${account.email}`;

        const repository = new gcp.artifactregistry.Repository(`${name}-repository`, {
            project: args.gcpProject,
            location: args.region,
            repositoryId,
            format: "DOCKER",
            description: `Images of the delegated deployer ${deployer.name}`,
        }, { parent: this });
        new gcp.artifactregistry.RepositoryIamMember(`${name}-repository-writer`, {
            project: args.gcpProject,
            location: args.region,
            repository: repository.repositoryId,
            role: "roles/artifactregistry.writer",
            member,
        }, { parent: this });

        const storeRole = new gcp.projects.IAMCustomRole(`${name}-store-role`, {
            project: args.gcpProject,
            roleId: deployerStoreRoleId(deployer.accountId),
            title: `Nagare inventory writer for ${deployer.name}`,
            description: "Read, write and delete inventory objects; granted only on the inventory bucket under a prefix condition.",
            permissions: deployerStorePermissions,
        }, { parent: this });
        new gcp.storage.BucketIAMMember(`${name}-store`, {
            bucket: args.inventoryBucket,
            role: storeRole.name,
            member,
            condition: {
                title: "nagare-inventory-deployer",
                description: "The context's inventory objects, and the bucket for listing and its metadata.",
                expression: deployerStoreCondition(args.inventoryBucket, args.inventoryPrefix),
            },
        }, { parent: this });

        this.email = account.email;
        this.repository = repository.repositoryId;
        this.registerOutputs({ email: this.email, repository: this.repository });
    }
}

// The delegation's repository ID, refusing an invalid account ID too.
export function validateDelegatedDeployer(args: NagareDelegatedDeployerArgs): string {
    const deployer = args.deployer;
    if (!/^[a-z][-a-z0-9]{4,28}[a-z0-9]$/.test(deployer.accountId)) {
        throw new Error(`delegated deployer ${deployer.name} has an invalid service account ID ${deployer.accountId}`);
    }
    return delegatedRepositoryId(args.gcpProject, args.region, args.platformRepositoryId, deployer);
}

// The repository ID of the delegation's image repository, refusing a
// repository outside this project and region, and the platform's own.
export function delegatedRepositoryId(gcpProject: string, region: string, platformRepositoryId: string, deployer: DelegatedDeployerEntry): string {
    const host = `${region}-docker.pkg.dev`;
    const segments = deployer.imageRepository.split("/");
    if (segments.length < 3 || segments[0] !== host || segments[1] !== gcpProject || segments.some((segment) => segment === "")) {
        throw new Error(`delegated deployer ${deployer.name}: image repository ${deployer.imageRepository} is not under ${host}/${gcpProject}/`);
    }
    const repositoryId = segments[2];
    if (!/^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$/.test(repositoryId)) {
        throw new Error(`delegated deployer ${deployer.name}: ${repositoryId} is not an Artifact Registry repository ID`);
    }
    if (repositoryId === platformRepositoryId) {
        throw new Error(`delegated deployer ${deployer.name}: image repository ${deployer.imageRepository} is the platform's shared repository ${platformRepositoryId}`);
    }
    return repositoryId;
}

// Custom role IDs allow letters, digits, underscores and periods.
export function deployerStoreRoleId(accountId: string): string {
    return `nagareInventoryWriter_${accountId.replace(/-/g, "_")}`;
}

// Object names are projects/_/buckets/<bucket>/objects/<name>; the bucket's
// own name is projects/_/buckets/<bucket>.
export function deployerStoreCondition(bucket: string, prefix: string): string {
    const bucketName = `projects/_/buckets/${bucket}`;
    const root = `${bucketName}/objects/${prefix.replace(/^\/+|\/+$/g, "")}/`;
    return [
        `resource.name == "${bucketName}"`,
        `resource.name.startsWith("${root}")`,
    ].join(" || ");
}

// The derived config: a JSON list of entries, each with distinct names,
// accounts and repositories.
export function parseDelegatedDeployers(raw: string | undefined): DelegatedDeployerEntry[] {
    if (raw === undefined || raw.trim() === "") return [];
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) throw new Error("nagare:delegatedDeployers must be a JSON list");
    const entries = parsed.map((value): DelegatedDeployerEntry => {
        const entry = value as Record<string, unknown>;
        if (entry === null || typeof entry !== "object"
            || typeof entry.name !== "string" || !/^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$/.test(entry.name)
            || typeof entry.accountId !== "string" || typeof entry.imageRepository !== "string"
            || (entry.disabled !== undefined && typeof entry.disabled !== "boolean")) {
            throw new Error("each nagare:delegatedDeployers entry needs a DNS-label name, an accountId and an imageRepository");
        }
        return { name: entry.name, accountId: entry.accountId, imageRepository: entry.imageRepository, ...(entry.disabled === true ? { disabled: true } : {}) };
    });
    for (const field of ["name", "accountId", "imageRepository"] as const) {
        const values = entries.map((entry) => entry[field]);
        if (new Set(values).size !== values.length) throw new Error(`nagare:delegatedDeployers repeats a ${field}`);
    }
    return entries;
}
