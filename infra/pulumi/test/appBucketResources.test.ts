import { spawnSync } from "node:child_process";
import type * as pulumiModule from "@pulumi/pulumi";

// Pulumi reads PULUMI_CONFIG when it is first loaded, so a program run loads it only
// after setting its variant's config.
type Pulumi = typeof pulumiModule;

interface RecordedResource {
    type: string;
    name: string;
    inputs: Record<string, unknown>;
}

const projectNumber = "123456789012";
const poolPath = `projects/${projectNumber}/locations/global/workloadIdentityPools/nagare-intranet`;
const apiSubject = "system:serviceaccount:personal:nagare-wl-content-app";
const gatewaySubject = "system:serviceaccount:personal:nagare-wl-gateway";
// In the order the provider writes Google's JWK fields.
const jwks = { keys: [{ kty: "RSA", alg: "RS256", use: "sig", kid: "k1", n: "AQAB-modulus", e: "AQAB" }] };

function buckets(retired: boolean): unknown[] {
    return [{
        name: "publications",
        bucket: "example-project-intranet-publications",
        retired,
        expire: [{ prefix: "staging/", afterDays: 1 }],
        grants: [
            { subject: apiSubject, accountId: "nagare-wl-3f9a1c", access: "read-write", signUrls: true },
            { subject: gatewaySubject, accountId: "nagare-wl-77b0d2", access: "read-only", signUrls: false },
        ],
    }];
}

function assert(condition: boolean, message: string): void {
    if (!condition) throw new Error(message);
}

function same(left: unknown, right: unknown): boolean {
    return JSON.stringify(left) === JSON.stringify(right);
}

function refuses(action: () => unknown): boolean {
    try {
        action();
        return false;
    } catch {
        return true;
    }
}

function mocks(resources: RecordedResource[]): pulumiModule.runtime.Mocks {
    return {
        newResource: (args: pulumiModule.runtime.MockResourceArgs) => {
            resources.push({ type: args.type, name: args.name, inputs: args.inputs });
            const state: Record<string, unknown> = { ...args.inputs, name: args.inputs.name ?? args.name };
            if (args.type === "gcp:serviceaccount/account:Account") {
                state.email = `${String(args.inputs.accountId)}@example-project.iam.gserviceaccount.com`;
                state.name = `projects/example-project/serviceAccounts/${String(state.email)}`;
            }
            return { id: `${args.name}-id`, state };
        },
        call: (args: pulumiModule.runtime.MockCallArgs) => args.token === "gcp:organizations/getProject:getProject"
            ? { ...args.inputs, number: projectNumber }
            : args.inputs,
    };
}

// One run of the whole program under a variant's config, printed for the parent.
async function observeProgram(variant: string): Promise<void> {
    const config: Record<string, string> = {
        "gcp:project": "example-project",
        "gcp:region": "us-west1",
        "gcp:zone": "us-west1-a",
        "nagare:imageBucket": "example-images",
        "nagare:manageProjectApis": "false",
        "nagare:nagareImageSelfLink": "projects/example-project/global/images/nagare-image",
        "nagare:enableAdminApiReader": "true",
        "nagare:enableLifecycleWorker": "true",
    };
    if (variant !== "missing-identity") {
        config["nagare:workloadIdentity"] = JSON.stringify({ issuer: "https://kubernetes.default.svc.cluster.local", jwks: { keys: [{ ...jwks.keys[0], extra: "dropped" }] } });
    }
    if (variant === "buckets" || variant === "missing-identity") config["nagare:appBuckets"] = JSON.stringify(buckets(false));
    if (variant === "retired") config["nagare:appBuckets"] = JSON.stringify(buckets(true));
    if (variant === "empty") config["nagare:appBuckets"] = "[]";
    process.env.PULUMI_CONFIG = JSON.stringify(config);
    delete process.env.NAGARE_RESOURCE_DECLARATIONS;
    const resources: RecordedResource[] = [];
    const pulumi: Pulumi = await import("@pulumi/pulumi");
    await pulumi.runtime.setMocks(mocks(resources), "nagare", "intranet", true);
    await pulumi.runtime.runInPulumiStack(async () => {
        await import("../index");
        return {};
    });
    await pulumi.runtime.disconnect();
    process.stdout.write(`${JSON.stringify(resources)}\n`);
}

function runVariant(variant: string): RecordedResource[] {
    const result = spawnSync(process.execPath, [__filename, variant], { encoding: "utf8" });
    if (result.status !== 0) throw new Error(`program fixture ${variant} failed: ${result.stderr}${result.stdout}`);
    return (JSON.parse(result.stdout.trim()) as RecordedResource[])
        .sort((left, right) => `${left.type}\0${left.name}`.localeCompare(`${right.type}\0${right.name}`));
}

const bucketTypes = [
    "nagare:env:NagareWorkloadIdentity",
    "nagare:env:NagareAppBucket",
    "gcp:iam/workloadIdentityPool:WorkloadIdentityPool",
    "gcp:iam/workloadIdentityPoolProvider:WorkloadIdentityPoolProvider",
];

const isIamGrant = (type: string) => /IAMMember|IamMember|IAMBinding|IamBinding|IAMPolicy|IamPolicy/.test(type);

// EP-284: a context's app bucket is private and protected, each grant is one account with
// exactly its declared access, reachable only from its one pool subject, and no key.
async function main(): Promise<void> {
    const variant = process.argv[2];
    if (variant) {
        await observeProgram(variant);
        return;
    }
    const pulumi: Pulumi = await import("@pulumi/pulumi");
    const { NagareAppBucket, parseAppBuckets } = await import("../src/components/NagareAppBucket");
    const { googleJwksJson, parseWorkloadIdentity, workloadIdentityPoolId } = await import("../src/components/NagareWorkloadIdentity");

    const program = runVariant("buckets");
    const pool = program.filter((r) => r.type === "gcp:iam/workloadIdentityPool:WorkloadIdentityPool");
    assert(pool.length === 1 && pool[0].inputs.workloadIdentityPoolId === "nagare-intranet" && pool[0].inputs.project === "example-project",
        "the program does not create exactly one pool named after the context");
    const providers = program.filter((r) => r.type === "gcp:iam/workloadIdentityPoolProvider:WorkloadIdentityPoolProvider");
    assert(providers.length === 1, "the program does not create exactly one pool provider");
    const provider = providers[0].inputs;
    const oidc = provider.oidc as Record<string, unknown>;
    assert(provider.workloadIdentityPoolId === "nagare-intranet" && provider.workloadIdentityPoolProviderId === "kubernetes", "the provider is not the pool's kubernetes provider");
    assert(same(provider.attributeMapping, { "google.subject": "assertion.sub" }), "the provider maps more or less than google.subject from assertion.sub");
    assert(provider.attributeCondition === undefined, "the provider has an attribute condition");
    assert(oidc.issuerUri === "https://kubernetes.default.svc.cluster.local", "the provider does not trust the cluster's issuer");
    assert(same(oidc.allowedAudiences, [`https://iam.googleapis.com/${poolPath}/providers/kubernetes`]), "the provider does not allow exactly its own audience");
    assert(same(JSON.parse(String(oidc.jwksJson)), jwks), "the provider's uploaded JWKS is not the cluster's, with only Google's JWK fields");
    assert(oidc.jwksUri === undefined, "the provider fetches its keys instead of using the uploaded JWKS");
    // Google stores the JWKS in its own layout and reads it back so (seen on ep285); any other
    // spelling is a perpetual diff on oidc.jwksJson.
    assert(oidc.jwksJson === '{\n  "keys": [{\n    "kty": "RSA",\n    "alg": "RS256",\n    "use": "sig",\n    "kid": "k1",\n    "n": "AQAB-modulus",\n    "e": "AQAB"\n  }]\n}', "the uploaded JWKS is not in the layout Google stores");
    const two = googleJwksJson({ keys: [{ kty: "RSA", kid: "a" }, { kty: "RSA", kid: "b" }] });
    assert(two === '{\n  "keys": [{\n    "kty": "RSA",\n    "kid": "a"\n  }, {\n    "kty": "RSA",\n    "kid": "b"\n  }]\n}' && same(JSON.parse(two), { keys: [{ kty: "RSA", kid: "a" }, { kty: "RSA", kid: "b" }] }), "two keys are not laid out as Google stores them");

    const bucket = program.filter((r) => r.type === "gcp:storage/bucket:Bucket" && r.name === "nagare-bucket-publications-bucket");
    assert(bucket.length === 1, "the program does not create the app bucket");
    const b = bucket[0].inputs;
    assert(b.name === "example-project-intranet-publications" && b.location === "us-west1" && b.project === "example-project", "the bucket is not the derived name in the context's region");
    assert(b.uniformBucketLevelAccess === true, "the bucket allows object ACLs");
    assert(b.publicAccessPrevention === "enforced", "the bucket does not enforce public access prevention");
    assert(same(b.versioning, { enabled: false }), "the bucket keeps versions");
    assert(b.forceDestroy === undefined, "the bucket can be force-destroyed");
    assert(same(b.lifecycleRules, [{ action: { type: "Delete" }, condition: { age: 1, matchesPrefixes: ["staging/"] } }]), "the bucket's lifecycle is not exactly the expiry rule");

    const accounts = program.filter((r) => r.type === "gcp:serviceaccount/account:Account" && r.name.startsWith("nagare-bucket-"));
    assert(same(accounts.map((a) => a.inputs.accountId).sort(), ["nagare-wl-3f9a1c", "nagare-wl-77b0d2"]), "the grants are not one account each");
    assert(accounts.every((a) => a.inputs.disabled === false && a.inputs.project === "example-project"), "an active bucket's account is disabled");
    const emailOf = (accountId: string) => `${accountId}@example-project.iam.gserviceaccount.com`;
    const accountPath = (accountId: string) => `projects/example-project/serviceAccounts/${emailOf(accountId)}`;
    const grantsOf = (accountId: string) => program.filter((r) => isIamGrant(r.type)
        && (String(r.inputs.member).includes(emailOf(accountId)) || r.inputs.serviceAccountId === accountPath(accountId)));
    const expected = (accountId: string, role: string, subject: string, signs: boolean) => [
        { type: "gcp:storage/bucketIAMMember:BucketIAMMember", bucket: "example-project-intranet-publications", role, member: `serviceAccount:${emailOf(accountId)}` },
        { type: "gcp:serviceaccount/iAMMember:IAMMember", serviceAccountId: accountPath(accountId), role: "roles/iam.workloadIdentityUser", member: `principal://iam.googleapis.com/${poolPath}/subject/${subject}` },
        ...(signs ? [{ type: "gcp:serviceaccount/iAMMember:IAMMember", serviceAccountId: accountPath(accountId), role: "roles/iam.serviceAccountTokenCreator", member: `serviceAccount:${emailOf(accountId)}` }] : []),
    ].sort((left, right) => left.role.localeCompare(right.role));
    const actual = (accountId: string) => grantsOf(accountId).map((r) => ({
        type: r.type,
        ...(r.inputs.bucket !== undefined ? { bucket: r.inputs.bucket } : {}),
        ...(r.inputs.serviceAccountId !== undefined ? { serviceAccountId: r.inputs.serviceAccountId } : {}),
        role: String(r.inputs.role),
        member: r.inputs.member,
        ...(r.inputs.condition !== undefined ? { condition: r.inputs.condition } : {}),
    })).sort((left, right) => left.role.localeCompare(right.role));
    assert(same(actual("nagare-wl-3f9a1c"), expected("nagare-wl-3f9a1c", "roles/storage.objectUser", apiSubject, true)),
        `the read-write signing grant is not object user, its one subject and token creator on itself: ${JSON.stringify(actual("nagare-wl-3f9a1c"))}`);
    assert(same(actual("nagare-wl-77b0d2"), expected("nagare-wl-77b0d2", "roles/storage.objectViewer", gatewaySubject, false)),
        `the read-only grant is not object viewer and its one subject: ${JSON.stringify(actual("nagare-wl-77b0d2"))}`);

    for (const [label, resources] of Object.entries({ buckets: program, retired: runVariant("retired") })) {
        assert(!resources.some((r) => r.type === "gcp:serviceaccount/key:Key" || r.type.includes("hmacKey")), `${label}: the program creates a key`);
        for (const grant of resources.filter((r) => isIamGrant(r.type))) {
            const members = [grant.inputs.member, ...((grant.inputs.members as unknown[] | undefined) ?? [])].map(String);
            assert(!members.some((m) => m.startsWith("allUsers") || m.startsWith("allAuthenticatedUsers")), `${label}: ${grant.name} grants a public member`);
            if (grant.type.startsWith("gcp:projects/") || grant.type.startsWith("gcp:organizations/") || grant.type.startsWith("gcp:folder/")) {
                assert(!members.some((m) => m.includes("nagare-wl-")), `${label}: ${grant.name} grants a bucket account a project-level role`);
            }
        }
    }

    // A retired bucket keeps every resource and every input except its accounts' disabled flag.
    const retired = runVariant("retired");
    assert(same(retired.map((r) => `${r.type}::${r.name}`), program.map((r) => `${r.type}::${r.name}`)), "a retired bucket changed its resources");
    const retiredAccounts = retired.filter((r) => r.type === "gcp:serviceaccount/account:Account" && r.name.startsWith("nagare-bucket-"));
    assert(retiredAccounts.length === 2 && retiredAccounts.every((a) => a.inputs.disabled === true), "a retired bucket's accounts are not disabled");
    const withoutDisabled = (resources: RecordedResource[]) => resources.map((r) => ({ ...r, inputs: { ...r.inputs, disabled: undefined } }));
    assert(same(withoutDisabled(retired), withoutDisabled(program)), "a retired bucket changed more than its accounts' disabled flag");

    // No bucket: no bucket resource and no pool, even with an issuer in the config.
    for (const label of ["none", "empty"]) {
        const none = runVariant(label);
        assert(!none.some((r) => bucketTypes.includes(r.type) || r.name.startsWith("nagare-bucket-") || r.name.startsWith("nagare-workload-identity")),
            `${label}: a context with no bucket creates bucket or pool resources`);
        assert(same(none.map((r) => `${r.type}::${r.name}`), program.filter((r) => !r.name.startsWith("nagare-bucket-") && !r.name.startsWith("nagare-workload-identity")).map((r) => `${r.type}::${r.name}`)),
            `${label}: the buckets change resources outside their own components`);
    }
    assert(refuses(() => runVariant("missing-identity")), "a bucket without nagare:workloadIdentity was accepted");

    // The bucket is protected; its component sets the option on the bucket alone.
    const resources: RecordedResource[] = [];
    await pulumi.runtime.setMocks(mocks(resources), "nagare", "intranet", true);
    const [entry] = parseAppBuckets(JSON.stringify(buckets(false)));
    const component = new NagareAppBucket("nagare-bucket-publications", {
        gcpProject: "example-project",
        region: "us-west1",
        projectNumber,
        poolId: "nagare-intranet",
        entry,
    });
    await new Promise((resolve) => setTimeout(resolve, 50));
    await pulumi.runtime.disconnect();
    assert((component.bucket as unknown as { __protect?: boolean }).__protect === true, "the app bucket is not protected");

    // The derived config is refused when it is not what nagarectl derives.
    const withGrant = (grant: Record<string, unknown>) => JSON.stringify([{ ...(buckets(false)[0] as object), grants: [{ subject: apiSubject, accountId: "nagare-wl-3f9a1c", access: "read-write", signUrls: false, ...grant }] }]);
    assert(same(parseAppBuckets(undefined), []) && same(parseAppBuckets(" "), []) && same(parseAppBuckets("[]"), []), "an absent bucket list is not empty");
    for (const raw of [
        "{}",
        withGrant({ subject: "system:serviceaccount:personal:default" }),
        withGrant({ subject: `system:serviceaccount:${"n".repeat(63)}:nagare-wl-${"w".repeat(60)}` }),
        withGrant({ accountId: "nagare-wl-this-account-id-is-too-long" }),
        withGrant({ access: "admin" }),
        withGrant({ signUrls: "yes" }),
        JSON.stringify([{ ...(buckets(false)[0] as object), expire: [{ prefix: "staging/", afterDays: 0 }] }]),
        JSON.stringify([{ ...(buckets(false)[0] as object), retired: "no" }]),
        JSON.stringify([{ ...(buckets(false)[0] as object), bucket: "Bad_Name" }]),
        JSON.stringify([buckets(false)[0], { ...(buckets(false)[0] as object), name: "other", bucket: "example-project-intranet-other" }]),
        JSON.stringify([{ ...(buckets(false)[0] as object), grants: [(buckets(false)[0] as { grants: unknown[] }).grants[0], { subject: apiSubject, accountId: "nagare-wl-000000", access: "read-only", signUrls: false }] }]),
    ]) {
        assert(refuses(() => parseAppBuckets(raw)), `nagare:appBuckets accepted ${raw}`);
    }
    assert(parseWorkloadIdentity(undefined) === undefined, "an absent workload identity is not absent");
    for (const raw of [
        JSON.stringify({ issuer: "http://kubernetes.default.svc", jwks }),
        JSON.stringify({ issuer: "https://kubernetes.default.svc", jwks: { keys: [] } }),
        JSON.stringify({ issuer: "https://kubernetes.default.svc" }),
    ]) {
        assert(refuses(() => parseWorkloadIdentity(raw)), `nagare:workloadIdentity accepted ${raw}`);
    }
    assert(workloadIdentityPoolId("intranet") === "nagare-intranet", "a short context's pool ID changed");
    const long = workloadIdentityPoolId("a-context-name-that-is-far-too-long");
    assert(/^nagare-[0-9a-f]{16}$/.test(long) && long === workloadIdentityPoolId("a-context-name-that-is-far-too-long"), "a long context's pool ID is not a stable digest");
    console.log("ok");
}

void main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
