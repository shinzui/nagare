import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import {
    decodeCloudDeclarationBundle,
    collectionTypes,
    NativeRegistration,
    validateResourceRegistrations,
} from "../src/resourceDeclarations";

function canonicalJson(value: unknown): string {
    if (value === null || typeof value === "boolean" || typeof value === "number" || typeof value === "string") return JSON.stringify(value);
    if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
    const object = value as Record<string, unknown>;
    return `{${Object.keys(object).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(object[key])}`).join(",")}}`;
}

function digest(value: unknown): string {
    return createHash("sha256").update(canonicalJson(value), "utf8").digest("hex");
}

const registration: NativeRegistration = {
    resourceId: "platform:cloud/network/vpc",
    pulumiType: "gcp:compute/network:Network",
    pulumiName: "nagare-network-net",
    pulumiUrn: "urn:pulumi:dev::nagare::gcp:compute/network:Network::nagare-network-net",
    specDigest: "1".repeat(64),
    class: "managed",
};

const wire = {
    version: 1,
    context: "dev",
    project: "example-project",
    stack: "dev",
    scope: { kind: "Platform", name: "cloud" },
    resources: [],
    registrations: [registration],
    bundleDigest: digest([registration]),
};

const decoded = decodeCloudDeclarationBundle(JSON.stringify(wire));
validateResourceRegistrations(decoded.registrations, [{ pulumiType: registration.pulumiType, pulumiName: registration.pulumiName }]);

const nestedRegistration: NativeRegistration = {
    ...registration,
    pulumiUrn: "urn:pulumi:dev::nagare::nagare:env:NagarePerimeter$gcp:compute/network:Network::nagare-network-net",
};
decodeCloudDeclarationBundle(JSON.stringify({
    ...wire,
    registrations: [nestedRegistration],
    bundleDigest: digest([nestedRegistration]),
}));

let refusedUnknown = false;
try {
    validateResourceRegistrations(decoded.registrations, [{ pulumiType: "gcp:storage/bucket:Bucket", pulumiName: "foreign" }]);
} catch {
    refusedUnknown = true;
}
if (!refusedUnknown) throw new Error("registration parity accepted missing and unexpected resources");

let refusedDigest = false;
try {
    decodeCloudDeclarationBundle(JSON.stringify({ ...wire, bundleDigest: "0".repeat(64) }));
} catch {
    refusedDigest = true;
}
if (!refusedDigest) throw new Error("declaration decoder accepted a changed registration digest");

console.log("ok");

// Exact omission is a new protocol, never an incidental v1 optional field.
decodeCloudDeclarationBundle(JSON.stringify({...wire, version: 2, collections: [registration]}));
for (const invalid of [
    {...wire, collections: [registration]},
    {...wire, version: 2, collections: []},
    {...wire, version: 2, collections: [registration, registration]},
    {...wire, version: 2, collections: [{...registration, specDigest: "2".repeat(64)}]},
    {...wire, version: 2, collections: [{...registration, class: {bookkeeping: "provider"}}]},
]) {
    let refused = false;
    try { decodeCloudDeclarationBundle(JSON.stringify(invalid)); } catch { refused = true; }
    if (!refused) throw new Error("unsafe collection protocol accepted");
}

const protectedRegistration = {...registration, pulumiType: "gcp:compute/disk:Disk",
    pulumiUrn: "urn:pulumi:dev::nagare::gcp:compute/disk:Disk::nagare-network-net"};
let refusedProtected = false;
try {
    decodeCloudDeclarationBundle(JSON.stringify({...wire, version: 2,
        registrations: [protectedRegistration], collections: [protectedRegistration],
        bundleDigest: digest([protectedRegistration])}));
} catch { refusedProtected = true; }
if (!refusedProtected) throw new Error("protected disk omission accepted");

const collectionProtocol = JSON.parse(readFileSync("resource-collection-protocol.json", "utf8"));
if (collectionProtocol.version !== 1 || collectionProtocol.declarationVersion !== 2
    || JSON.stringify([...collectionProtocol.types].sort()) !== JSON.stringify([...collectionTypes].sort())) {
    throw new Error("packaged collection capability differs from the actual declaration guard");
}
