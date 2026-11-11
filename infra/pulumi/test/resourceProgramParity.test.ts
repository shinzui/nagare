import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

type Registration = { pulumiType: string; pulumiName: string };
type CatalogEntry = { key?: string; type: string; name: string; parent: string | null; layer: number };

async function observeProgram(variant: string): Promise<void> {
    const observed: Registration[] = [];
    const config: Record<string, string> = {
        "gcp:project": "example-project",
        "gcp:region": "us-west1",
        "gcp:zone": "us-west1-a",
        "nagare:imageBucket": "example-images",
    };
    if (variant.includes("foundation-managed")) config["nagare:manageProjectApis"] = "false";
    if (variant.includes("image") || variant.includes("cdn-")) config["nagare:nagareImageSelfLink"] = "projects/example-project/global/images/nagare-image";
    if (variant.includes("cache")) config["nagare:enableNixCache"] = "true";
    if (variant.includes("tunnel")) config["nagare:ingress"] = "cloudflare-tunnel";
    if (variant.includes("admin-api")) config["nagare:enableAdminApiReader"] = "true";
    if (variant.includes("delegated-deployer")) {
        config["nagare:delegatedDeployers"] = JSON.stringify([
            { name: "example", accountId: "nagare-deployer-example", imageRepository: "us-west1-docker.pkg.dev/example-project/example-images" },
        ]);
    }
    if (variant.includes("cdn-legacy")) {
        config["nagare:enableCdn"] = "true";
        config["nagare:cdnCertificateMode"] = "legacy";
    }
    if (variant.includes("cdn-manager")) {
        config["nagare:enableCdn"] = "true";
        config["nagare:cdnCertificateMode"] = "certificate-map";
    }
    if (variant.includes("cdn-prepare")) {
        config["nagare:enableCdn"] = "true";
        config["nagare:cdnCertificateMode"] = "prepare";
    }
    process.env.PULUMI_CONFIG = JSON.stringify(config);
    if (process.env.NAGARE_TEST_DECLARATIONS) {
        process.env.NAGARE_RESOURCE_DECLARATIONS = process.env.NAGARE_TEST_DECLARATIONS;
    } else {
        delete process.env.NAGARE_RESOURCE_DECLARATIONS;
    }
    const pulumi = await import("@pulumi/pulumi");
    await pulumi.runtime.setMocks({
        call: (args) => args.inputs,
        newResource: (args) => {
            if (args.type.startsWith("gcp:") || args.type.startsWith("nagare:")) {
                observed.push({ pulumiType: args.type, pulumiName: args.name });
            }
            return {
                id: `${args.name}-id`,
                state: {
                    ...args.inputs,
                    id: `${args.name}-id`,
                    name: args.inputs.name ?? args.name,
                    selfLink: `https://example.invalid/${args.name}`,
                    email: `${args.name}@example-project.iam.gserviceaccount.com`,
                    accessId: `${args.name}-access-id`,
                    secret: `${args.name}-secret`,
                    managed: args.inputs.managed ? { ...args.inputs.managed, state: "ACTIVE" } : undefined,
                    managedZone: args.inputs.managedZone ?? "nagare-zone",
                    dnsResourceRecords: [{ name: "_acme.example.invalid.", type: "CNAME", data: "authorization.example.invalid." }],
                },
            };
        },
    }, "nagare", "dev", true);
    await pulumi.runtime.runInPulumiStack(async () => {
        await import("../index");
        return {};
    });
    await pulumi.runtime.disconnect();
    observed.sort((left, right) => `${left.pulumiType}\0${left.pulumiName}`.localeCompare(`${right.pulumiType}\0${right.pulumiName}`));
    process.stdout.write(`${JSON.stringify(observed)}\n`);
}

function runVariant(variant: string, declarations?: string): Registration[] {
    const env = { ...process.env };
    if (declarations) env.NAGARE_TEST_DECLARATIONS = declarations;
    const result = spawnSync(process.execPath, [__filename, variant], { encoding: "utf8", env });
    if (result.status !== 0) throw new Error(`resource program fixture ${variant} failed: ${result.stderr}${result.stdout}`);
    return JSON.parse(result.stdout.trim()) as Registration[];
}

function canonicalJson(value: unknown): string {
    if (value === null || typeof value === "boolean" || typeof value === "number" || typeof value === "string") return JSON.stringify(value);
    if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
    const object = value as Record<string, unknown>;
    return `{${Object.keys(object).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(object[key])}`).join(",")}}`;
}

function verifyGuardedVariant(variant: string, observed: Registration[]): void {
    const temporary = mkdtempSync(join(tmpdir(), "nagare-resource-parity-"));
    try {
        const registrations = observed.map((registration, index) => ({
            resourceId: `platform:cloud/native-${index}/resource`,
            ...registration,
            pulumiUrn: `urn:pulumi:dev::nagare::${registration.pulumiType}::${registration.pulumiName}`,
            specDigest: "1".repeat(64),
            class: "managed",
        }));
        const declarationPath = join(temporary, "declarations.json");
        writeFileSync(declarationPath, canonicalJson({
            version: 1,
            context: "dev",
            project: "example-project",
            stack: "dev",
            scope: [{ kind: "Platform", name: "cloud" }],
            resources: [],
            registrations,
            bundleDigest: createHash("sha256").update(canonicalJson(registrations), "utf8").digest("hex"),
        }));
        const guarded = runVariant(variant, declarationPath);
        assert(JSON.stringify(guarded) === JSON.stringify(observed), `${variant} declaration guard changed complete membership`);
    } finally {
        rmSync(temporary, { recursive: true, force: true });
    }
}

function verifyCollectedVariant(variant: string, observed: Registration[], omittedNames: string[]): void {
    const temporary = mkdtempSync(join(tmpdir(), "nagare-collection-parity-"));
    try {
        const registrations = observed.map((registration, index) => ({
            resourceId: `platform:cloud/native-${index}/resource`, ...registration,
            pulumiUrn: `urn:pulumi:dev::nagare::${registration.pulumiType}::${registration.pulumiName}`,
            specDigest: "1".repeat(64), class: "managed",
        }));
        const collections = registrations.filter((r) => omittedNames.includes(r.pulumiName));
        const declarationPath = join(temporary, "declarations.json");
        writeFileSync(declarationPath, canonicalJson({
            version: 2, context: "dev", project: "example-project", stack: "dev",
            scope: [{kind: "Platform", name: "cloud"}], resources: [], registrations, collections,
            bundleDigest: createHash("sha256").update(canonicalJson(registrations), "utf8").digest("hex"),
        }));
        const actual = runVariant(variant, declarationPath);
        const expected = observed.filter((r) => !omittedNames.includes(r.pulumiName));
        assert(JSON.stringify(actual) === JSON.stringify(expected), "collection changed an unselected registration");
    } finally {
        rmSync(temporary, {recursive: true, force: true});
    }
}

function names(values: Registration[]): Set<string> {
    return new Set(values.map((value) => `${value.pulumiType}::${value.pulumiName}`));
}

function assert(condition: boolean, message: string): void {
    if (!condition) throw new Error(message);
}

async function main(): Promise<void> {
    const variant = process.argv[2];
    if (variant) {
        await observeProgram(variant);
        return;
    }
    const base = runVariant("base");
    const foundationManaged = runVariant("foundation-managed");
    const foundationManagedCache = runVariant("foundation-managed-cache");
    const foundationManagedImage = runVariant("foundation-managed-image");
    const foundationManagedAdminApi = runVariant("foundation-managed-admin-api");
    const foundationManagedDeployer = runVariant("foundation-managed-delegated-deployer");
    // ADR 34: a tunnel context keeps only the IAP SSH rule and declares no Cloud DNS.
    const tunnel = runVariant("foundation-managed-image-tunnel");
    const tunnelNames = names(tunnel);
    const tunnelOmitted = ["nagare-network-fw-web", "nagare-network-fw-lb-health", "nagare-network-fw-tailscale", "nagare-zone", "nagare-iam-dns-zone", "nagare-iam-dns-read", "nagare-wildcard", "nagare-apex"];
    for (const name of tunnelOmitted) {
        assert(![...tunnelNames].some((key) => String(key).endsWith(`::${name}`) || String(key) === name), `tunnel variant still declares ${name}`);
    }
    assert([...tunnelNames].some((key) => String(key).includes("nagare-network-fw-iap-ssh")), "tunnel variant lost the IAP SSH rule");
    verifyGuardedVariant("foundation-managed-image-tunnel", tunnel);
    const image = runVariant("image");
    const cache = runVariant("cache");
    const legacyCdn = runVariant("cdn-legacy");
    const prepareCdn = runVariant("cdn-prepare");
    const managerCdn = runVariant("cdn-manager");
    for (const [label, registrations] of Object.entries({ base, foundationManaged, foundationManagedCache, foundationManagedImage, image, cache, legacyCdn, prepareCdn, managerCdn })) {
        assert(names(registrations).size === registrations.length, `${label} contains duplicate native registrations`);
    }
    verifyCollectedVariant("foundation-managed", foundationManaged, ["nagare-network-fw-web"]);
    verifyCollectedVariant("foundation-managed", foundationManaged,
        ["nagare-network-fw-web", "nagare-network-fw-iap-ssh", "nagare-network-fw-lb-health", "nagare-network-fw-tailscale", "nagare-network-subnet"]);
    verifyCollectedVariant("foundation-managed-image", foundationManagedImage, ["nagare-01"]);
    verifyCollectedVariant("foundation-managed", foundationManaged, ["nagare-nix-cache"]);
    for (const [variant, observed, selected] of [
        ["foundation-managed-cache", foundationManagedCache, ["nagare-nix-cache"]],
        ["foundation-managed", foundationManaged, ["nagare-network"]],
    ] as [string, Registration[], string[]][]) {
        let refused = false;
        try { verifyCollectedVariant(variant, observed, selected); } catch { refused = true; }
        assert(refused, "component omission silently removed unselected child resources");
    }
    verifyGuardedVariant("base", base);
    verifyGuardedVariant("foundation-managed", foundationManaged);
    verifyGuardedVariant("foundation-managed-cache", foundationManagedCache);
    verifyGuardedVariant("foundation-managed-image", foundationManagedImage);
    verifyGuardedVariant("foundation-managed-admin-api", foundationManagedAdminApi);
    verifyGuardedVariant("foundation-managed-delegated-deployer", foundationManagedDeployer);
    verifyGuardedVariant("image", image);
    verifyGuardedVariant("cache", cache);
    verifyGuardedVariant("cdn-legacy", legacyCdn);
    verifyGuardedVariant("cdn-prepare", prepareCdn);
    verifyGuardedVariant("cdn-manager", managerCdn);
    assert(base.length === 31, `base cloud topology changed: expected 31 registrations, got ${base.length}`);
    assert(foundationManaged.length === base.length - 7,
        "foundation-managed topology must omit the seven API registrations owned by the reviewed foundation");
    const catalog = JSON.parse(readFileSync(join(__dirname, "../../resource-catalog.json"), "utf8")) as {
        version: number;
        foundationManaged: CatalogEntry[];
        nixCacheEnabled: CatalogEntry[];
        imageEnabled: CatalogEntry[];
        cdnEnabled: CatalogEntry[];
        adminApiReaderEnabled: CatalogEntry[];
        delegatedDeployerEnabled: CatalogEntry[];
    };
    assert(catalog.version === 1, "cloud resource catalog version changed");
    const catalogNames = catalog.foundationManaged.map(({ type, name }) => `${type}::${name}`).sort();
    const nativeNames = foundationManaged.map(({ pulumiType, pulumiName }) => `${pulumiType}::${pulumiName}`).sort();
    assert(JSON.stringify(catalogNames) === JSON.stringify(nativeNames),
        "reviewed cloud catalog differs from registrations in the actual Pulumi program");
    const withCache = catalog.foundationManaged.concat(catalog.nixCacheEnabled);
    const cacheNames = withCache.map(({ type, name }) => `${type}::${name}`).sort();
    const nativeCacheNames = foundationManagedCache.map(({ pulumiType, pulumiName }) => `${pulumiType}::${pulumiName}`).sort();
    assert(JSON.stringify(cacheNames) === JSON.stringify(nativeCacheNames),
        "reviewed cloud cache catalog differs from registrations in the actual Pulumi program");
    const withImage = catalog.foundationManaged.concat(catalog.imageEnabled);
    const imageNames = withImage.map(({ type, name }) => `${type}::${name}`).sort();
    const nativeImageNames = foundationManagedImage.map(({ pulumiType, pulumiName }) => `${pulumiType}::${pulumiName}`).sort();
    assert(JSON.stringify(imageNames) === JSON.stringify(nativeImageNames),
        "reviewed cloud image catalog differs from registrations in the actual Pulumi program");
    // EP-198: the admin API reader is exactly what enableAdminApiReader adds.
    const withAdminApi = catalog.foundationManaged.concat(catalog.adminApiReaderEnabled);
    const adminApiNames = withAdminApi.map(({ type, name }) => `${type}::${name}`).sort();
    const nativeAdminApiNames = foundationManagedAdminApi.map(({ pulumiType, pulumiName }) => `${pulumiType}::${pulumiName}`).sort();
    assert(JSON.stringify(adminApiNames) === JSON.stringify(nativeAdminApiNames),
        "reviewed cloud admin API reader catalog differs from registrations in the actual Pulumi program");
    // EP-198: an existing context enables the reader later. Its creates become one grouped
    // operation, and an existing member ordered after any of them would wait for the group
    // while the group waits for it. Every reader layer is therefore above every other one.
    const otherLayers = catalog.foundationManaged.concat(catalog.nixCacheEnabled, catalog.imageEnabled, catalog.cdnEnabled).map((entry) => entry.layer);
    const readerFloor = Math.min(...catalog.adminApiReaderEnabled.map((entry) => entry.layer));
    assert(readerFloor > Math.max(...otherLayers),
        "an admin API reader layer is not above every other catalog layer, so an existing member can be ordered after the reader's grouped create");
    // F43: the CDN section is exactly what the legacy-certificate CDN adds to the image topology.
    const cdnNames = catalog.cdnEnabled.map(({ type, name }) => `${type}::${name}`).sort();
    const imageSet = names(image);
    const nativeCdnNames = [...names(legacyCdn)].filter((name) => !imageSet.has(name)).sort();
    assert(JSON.stringify(cdnNames) === JSON.stringify(nativeCdnNames),
        "reviewed cloud CDN catalog differs from registrations in the actual Pulumi program");
    // EP-248 D6: the delegated deployer section is a template, instantiated once per
    // delegation by nagarectl with the deployer's name for {deployer}: exactly what one
    // nagare:delegatedDeployers entry adds. Its layers sit above every other section's
    // for the same reason as the reader's.
    const deployerEntries = catalog.delegatedDeployerEnabled.map((entry) => ({
        ...entry,
        key: (entry.key ?? entry.name).replace(/\{deployer\}/g, "example"),
        name: entry.name.replace(/\{deployer\}/g, "example"),
        parent: entry.parent === null ? null : entry.parent.replace(/\{deployer\}/g, "example"),
    }));
    assert(catalog.delegatedDeployerEnabled.every((entry) => entry.name.includes("{deployer}")), "a delegated deployer catalog entry is not per deployer");
    const deployerNames = catalog.foundationManaged.concat(deployerEntries).map(({ type, name }) => `${type}::${name}`).sort();
    const nativeDeployerNames = foundationManagedDeployer.map(({ pulumiType, pulumiName }) => `${pulumiType}::${pulumiName}`).sort();
    assert(JSON.stringify(deployerNames) === JSON.stringify(nativeDeployerNames),
        "reviewed cloud delegated deployer catalog differs from registrations in the actual Pulumi program");
    const deployerFloor = Math.min(...deployerEntries.map((entry) => entry.layer));
    assert(deployerFloor > Math.max(...otherLayers, ...catalog.adminApiReaderEnabled.map((entry) => entry.layer)),
        "a delegated deployer layer is not above every other catalog layer");
    const allEntries = catalog.foundationManaged.concat(catalog.nixCacheEnabled, catalog.imageEnabled, catalog.cdnEnabled, catalog.adminApiReaderEnabled, deployerEntries);
    const byKey = new Map(allEntries.map((entry) => [entry.key ?? entry.name, entry]));
    assert(byKey.size === allEntries.length, "cloud catalog has duplicate logical keys");
    for (const entry of allEntries) {
        assert(Number.isInteger(entry.layer) && entry.layer >= 0, `invalid layer for ${entry.name}`);
        if (entry.parent === null) continue;
        const parent = byKey.get(entry.parent);
        assert(parent !== undefined && parent.layer < entry.layer,
            `cloud catalog parent must be in an earlier layer: ${entry.name}`);
    }
    assert(image.length === base.length + 2, "image-enabled topology must add the instance component and GCE instance");
    assert(cache.length === base.length + 3, "cache-enabled topology must add its bucket, IAM member, and HMAC key");
    assert(legacyCdn.length === base.length + 14, "legacy-CDN topology registration delta changed");
    assert(managerCdn.length === legacyCdn.length + 6, "Certificate Manager topology must retain the legacy certificate while adding six managed resources");
    assert(JSON.stringify(prepareCdn) === JSON.stringify(managerCdn), "Certificate preparation and activation must retain identical resource membership");
    assert(names(image).has("gcp:compute/instance:Instance::nagare-01"), "image topology omitted the GCE instance");
    assert(names(cache).has("gcp:storage/hmacKey:HmacKey::nagare-nix-cache-hmac"), "cache topology omitted its HMAC credential");
    assert(names(managerCdn).has("gcp:certificatemanager/certificateMap:CertificateMap::nagare-cdn-certificate-map"), "Certificate Manager topology omitted its map");
    console.log("ok");
}

void main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
