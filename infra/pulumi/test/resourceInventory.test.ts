import { createHash } from "node:crypto";
import {
    decodeCloudDeclarationBundle,
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
