import * as pulumi from "@pulumi/pulumi";
import {
    NagareDelegatedDeployer,
    deployerStoreCondition,
    deployerStorePermissions,
    parseDelegatedDeployers,
    validateDelegatedDeployer,
} from "../src/components/NagareDelegatedDeployer";

interface RecordedResource {
    type: string;
    name: string;
    inputs: Record<string, unknown>;
}

const base = {
    gcpProject: "example-project",
    region: "us-west1",
    platformRepositoryId: "nagare",
    inventoryBucket: "example-project-nagare-pulumi-state",
    inventoryPrefix: "nagare/intranet/inventory/",
};

// EP-248 D6: a delegated deployer is its own account with a repository-level
// writer grant and one prefix-conditioned store grant, and nothing at project level.
async function main(): Promise<void> {
    const resources: RecordedResource[] = [];
    await pulumi.runtime.setMocks({
        newResource: (args: pulumi.runtime.MockResourceArgs) => {
            resources.push({ type: args.type, name: args.name, inputs: args.inputs });
            const state: Record<string, unknown> = { ...args.inputs, name: args.inputs.name ?? `projects/example-project/roles/${String(args.inputs.roleId ?? args.name)}` };
            if (args.type === "gcp:serviceaccount/account:Account") state.email = `${String(args.inputs.accountId)}@example-project.iam.gserviceaccount.com`;
            return { id: `${args.name}-id`, state };
        },
        call: (args: pulumi.runtime.MockCallArgs) => args.inputs,
    }, "nagare", "intranet", true);

    const [entry] = parseDelegatedDeployers(JSON.stringify([
        { name: "kotei", accountId: "nagare-deployer-kotei", imageRepository: "us-west1-docker.pkg.dev/example-project/kotei-images/site" },
    ]));
    const deployer = new NagareDelegatedDeployer("nagare-delegated-deployer-kotei", { ...base, deployer: entry });
    const email = await (deployer.email as unknown as { promise(): Promise<string> }).promise();
    await pulumi.runtime.disconnect();

    const gcp = resources.filter((resource) => resource.type.startsWith("gcp:"));
    const types = gcp.map((resource) => resource.type).sort();
    assert(JSON.stringify(types) === JSON.stringify([
        "gcp:artifactregistry/repository:Repository",
        "gcp:artifactregistry/repositoryIamMember:RepositoryIamMember",
        "gcp:projects/iAMCustomRole:IAMCustomRole",
        "gcp:serviceaccount/account:Account",
        "gcp:storage/bucketIAMMember:BucketIAMMember",
    ]), `unexpected deployer resources: ${JSON.stringify(types)}`);
    assert(!gcp.some((resource) => /projects\/iAMMember|projects\/iAMBinding|projects\/iAMPolicy|serviceAccountKey|serviceaccount\/key/i.test(resource.type)),
        "a deployer resource grants a project-level role or creates a key");
    assert(email === "nagare-deployer-kotei@example-project.iam.gserviceaccount.com", "the account is not the derived ID");

    const repository = one(gcp, "gcp:artifactregistry/repository:Repository");
    assert(repository.inputs.repositoryId === "kotei-images" && repository.inputs.format === "DOCKER" && repository.inputs.location === "us-west1",
        `the repository is not the delegation's: ${JSON.stringify(repository.inputs)}`);
    const writer = one(gcp, "gcp:artifactregistry/repositoryIamMember:RepositoryIamMember");
    assert(writer.inputs.role === "roles/artifactregistry.writer" && writer.inputs.repository === "kotei-images",
        "the writer grant is not on the delegation's repository");
    assert(writer.inputs.member === `serviceAccount:${email}`, "the writer is not the deployer account");

    const role = one(gcp, "gcp:projects/iAMCustomRole:IAMCustomRole");
    assert(JSON.stringify([...(role.inputs.permissions as string[])].sort()) === JSON.stringify([
        "storage.buckets.get",
        "storage.objects.create",
        "storage.objects.delete",
        "storage.objects.get",
        "storage.objects.list",
    ]), `the store role has other permissions: ${JSON.stringify(role.inputs.permissions)}`);
    assert(JSON.stringify(deployerStorePermissions) === JSON.stringify([...deployerStorePermissions].sort()), "the permission list is not sorted");

    const grant = one(gcp, "gcp:storage/bucketIAMMember:BucketIAMMember");
    assert(grant.inputs.bucket === base.inventoryBucket, "the store grant is not on the inventory bucket");
    assert(grant.inputs.member === `serviceAccount:${email}`, "the store grant is not the deployer account");
    assert(String(grant.inputs.role).endsWith("nagareInventoryWriter_nagare_deployer_kotei"), "the store grant has the wrong role");
    const expression = (grant.inputs.condition as { expression: string }).expression;
    const bucketName = "projects/_/buckets/example-project-nagare-pulumi-state";
    assert(expression === `resource.name == "${bucketName}" || resource.name.startsWith("${bucketName}/objects/nagare/intranet/inventory/")`,
        `unexpected store condition: ${expression}`);
    assert(expression === deployerStoreCondition(base.inventoryBucket, "nagare/intranet/inventory"), "the condition is not the shared expression");
    assert(!expression.includes(`startsWith("${bucketName}/objects/nagare/intranet/inventory")`), "the condition admits a sibling of the prefix");
    assert(!expression.includes(`startsWith("${bucketName}")`), "the condition admits every object in the bucket");

    // Refusals, before any resource is declared.
    for (const [imageRepository, reason] of [
        ["us-west1-docker.pkg.dev/example-project/nagare/site", "the platform's shared repository"],
        ["us-west1-docker.pkg.dev/other-project/kotei/site", "another project"],
        ["us-east1-docker.pkg.dev/example-project/kotei/site", "another region"],
        ["ghcr.io/example/kotei", "another registry"],
        ["us-west1-docker.pkg.dev/example-project", "no repository"],
    ]) {
        refuses(() => validateDelegatedDeployer({ ...base, deployer: { ...entry, imageRepository } }), reason);
    }
    refuses(() => validateDelegatedDeployer({ ...base, deployer: { ...entry, accountId: "Bad_Account" } }), "an invalid account ID");
    assert(validateDelegatedDeployer({ ...base, deployer: entry }) === "kotei-images", "a valid deployer is refused");
    refuses(() => parseDelegatedDeployers(JSON.stringify([entry, { ...entry, accountId: "nagare-deployer-other" }])), "a repeated name");
    refuses(() => parseDelegatedDeployers("{}"), "a non-list config");
    assert(parseDelegatedDeployers(undefined).length === 0, "an absent config is not empty");
    process.stdout.write("delegated deployer resources: OK\n");
}

function one(resources: RecordedResource[], type: string): RecordedResource {
    const matching = resources.filter((resource) => resource.type === type);
    assert(matching.length === 1, `expected one ${type}, got ${matching.length}`);
    return matching[0];
}

function refuses(action: () => unknown, reason: string): void {
    let refused = false;
    try { action(); } catch { refused = true; }
    assert(refused, `accepted ${reason}`);
}

function assert(condition: boolean, message: string): void {
    if (!condition) throw new Error(message);
}

main().catch((error) => {
    process.stderr.write(`${String(error)}\n`);
    process.exit(1);
});
