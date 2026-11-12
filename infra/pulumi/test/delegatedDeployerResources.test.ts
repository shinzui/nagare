import * as pulumi from "@pulumi/pulumi";
import {
    NagareDelegatedDeployer,
    deployerStoreCondition,
    deployerStoreRoles,
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
// writer grant and two prefix-conditioned store grants of predefined roles, and
// nothing at project level.
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
    // D7: a revoked delegation keeps the same resources with its account disabled.
    const [revokedEntry] = parseDelegatedDeployers(JSON.stringify([
        { name: "former", accountId: "nagare-deployer-former", imageRepository: "us-west1-docker.pkg.dev/example-project/former-images", disabled: true },
    ]));
    new NagareDelegatedDeployer("nagare-delegated-deployer-former", { ...base, deployer: revokedEntry });
    const email = await (deployer.email as unknown as { promise(): Promise<string> }).promise();
    await pulumi.runtime.disconnect();

    const accounts = resources.filter((resource) => resource.type === "gcp:serviceaccount/account:Account");
    assert(accounts.find((a) => a.inputs.accountId === "nagare-deployer-former")?.inputs.disabled === true, "a revoked deployer's account is not disabled");
    assert(accounts.find((a) => a.inputs.accountId === "nagare-deployer-kotei")?.inputs.disabled === false, "an active deployer's account is disabled");
    assert(resources.filter((resource) => resource.name.includes("former") && resource.type.startsWith("gcp:")).length === 5, "a revoked deployer's resources changed");
    const gcp = resources.filter((resource) => resource.type.startsWith("gcp:") && !resource.name.includes("former"));
    const types = gcp.map((resource) => resource.type).sort();
    assert(JSON.stringify(types) === JSON.stringify([
        "gcp:artifactregistry/repository:Repository",
        "gcp:artifactregistry/repositoryIamMember:RepositoryIamMember",
        "gcp:serviceaccount/account:Account",
        "gcp:storage/bucketIAMMember:BucketIAMMember",
        "gcp:storage/bucketIAMMember:BucketIAMMember",
    ]), `unexpected deployer resources: ${JSON.stringify(types)}`);
    assert(!gcp.some((resource) => /projects\/iAMMember|projects\/iAMBinding|projects\/iAMPolicy|iAMCustomRole|serviceAccountKey|serviceaccount\/key/i.test(resource.type)),
        "a deployer resource grants a project-level role, defines a custom role or creates a key");
    assert(email === "nagare-deployer-kotei@example-project.iam.gserviceaccount.com", "the account is not the derived ID");

    const repository = one(gcp, "gcp:artifactregistry/repository:Repository");
    assert(repository.inputs.repositoryId === "kotei-images" && repository.inputs.format === "DOCKER" && repository.inputs.location === "us-west1",
        `the repository is not the delegation's: ${JSON.stringify(repository.inputs)}`);
    const writer = one(gcp, "gcp:artifactregistry/repositoryIamMember:RepositoryIamMember");
    assert(writer.inputs.role === "roles/artifactregistry.writer" && writer.inputs.repository === "kotei-images",
        "the writer grant is not on the delegation's repository");
    assert(writer.inputs.member === `serviceAccount:${email}`, "the writer is not the deployer account");

    const grants = gcp.filter((resource) => resource.type === "gcp:storage/bucketIAMMember:BucketIAMMember");
    assert(JSON.stringify(grants.map((grant) => String(grant.inputs.role)).sort()) === JSON.stringify(["roles/storage.bucketViewer", "roles/storage.objectUser"]),
        `the store grants are not the predefined roles: ${JSON.stringify(grants.map((grant) => grant.inputs.role))}`);
    assert(deployerStoreRoles.objects === "roles/storage.objectUser" && deployerStoreRoles.bucket === "roles/storage.bucketViewer", "the exported roles differ");
    for (const other of grants) {
        assert(other.inputs.bucket === base.inventoryBucket, "a store grant is not on the inventory bucket");
        assert(other.inputs.member === `serviceAccount:${email}`, "a store grant is not the deployer account");
    }
    const conditions = grants.map((grant) => (grant.inputs.condition as { expression: string }).expression);
    assert(conditions[0] === conditions[1], "the store grants have different conditions");
    const grant = grants[0];
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
