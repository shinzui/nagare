import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import * as pulumi from "@pulumi/pulumi";

export type RegistrationClass = "managed" | { bookkeeping: string };

export interface NativeRegistration {
    resourceId: string;
    pulumiType: string;
    pulumiName: string;
    pulumiUrn: string;
    specDigest: string;
    class: RegistrationClass;
}

export interface CloudDeclarationBundle {
    version: 1 | 2;
    context: string;
    project: string;
    stack: string;
    scope: unknown;
    resources: unknown[];
    registrations: NativeRegistration[];
    bundleDigest: string;
    collections?: NativeRegistration[];
}

export interface ObservedRegistration {
    pulumiType: string;
    pulumiName: string;
}

function canonicalJson(value: unknown): string {
    if (value === null || typeof value === "boolean" || typeof value === "number" || typeof value === "string") {
        return JSON.stringify(value);
    }
    if (Array.isArray(value)) {
        return `[${value.map(canonicalJson).join(",")}]`;
    }
    if (typeof value === "object") {
        const object = value as Record<string, unknown>;
        return `{${Object.keys(object).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(object[key])}`).join(",")}}`;
    }
    throw new Error(`unsupported value in canonical resource declaration: ${typeof value}`);
}

function sha256(value: string): string {
    return createHash("sha256").update(value, "utf8").digest("hex");
}

function registrationKey(type: string, name: string): string {
    return `${type}\u0000${name}`;
}

function isRegistration(value: unknown): value is NativeRegistration {
    if (value === null || typeof value !== "object") return false;
    const registration = value as Record<string, unknown>;
    return typeof registration.resourceId === "string"
        && typeof registration.pulumiType === "string"
        && typeof registration.pulumiName === "string"
        && typeof registration.pulumiUrn === "string"
        && /^urn:pulumi:/.test(registration.pulumiUrn)
        && typeof registration.specDigest === "string"
        && /^[0-9a-f]{64}$/.test(registration.specDigest)
        && (registration.class === "managed"
            || (registration.class !== null
                && typeof registration.class === "object"
                && typeof (registration.class as Record<string, unknown>).bookkeeping === "string"));
}

export function decodeCloudDeclarationBundle(bytes: string): CloudDeclarationBundle {
    const parsed: unknown = JSON.parse(bytes);
    if (parsed === null || typeof parsed !== "object") throw new Error("cloud declaration bundle must be an object");
    const bundle = parsed as Record<string, unknown>;
    if (bundle.version !== 1 && bundle.version !== 2) throw new Error("unsupported cloud declaration bundle version");
    if (typeof bundle.context !== "string" || typeof bundle.project !== "string" || typeof bundle.stack !== "string") {
        throw new Error("cloud declaration bundle identity is missing");
    }
    if (!Array.isArray(bundle.resources) || !Array.isArray(bundle.registrations) || !bundle.registrations.every(isRegistration)) {
        throw new Error("cloud declaration bundle registrations are invalid");
    }
    if (typeof bundle.bundleDigest !== "string" || bundle.bundleDigest !== sha256(canonicalJson(bundle.registrations))) {
        throw new Error("cloud declaration bundle registration digest mismatch");
    }
    const seen = new Set<string>();
    for (const registration of bundle.registrations as NativeRegistration[]) {
        const key = registrationKey(registration.pulumiType, registration.pulumiName);
        if (seen.has(key)) throw new Error(`duplicate declared native registration ${registration.pulumiType}::${registration.pulumiName}`);
        seen.add(key);
        const urnParts = registration.pulumiUrn.split("::");
        const qualifiedType = urnParts[urnParts.length - 2] ?? "";
        const urnName = urnParts[urnParts.length - 1] ?? "";
        const typeParts = qualifiedType.split("$");
        const leafType = typeParts[typeParts.length - 1];
        if (leafType !== registration.pulumiType || urnName !== registration.pulumiName) {
            throw new Error(`declared native registration URN disagrees with type/name: ${registration.resourceId}`);
        }
    }
    if (bundle.version === 1 && bundle.collections !== undefined) throw new Error("legacy declaration cannot omit resources");
    if (bundle.version === 2) {
        if (!Array.isArray(bundle.collections) || bundle.collections.length === 0 || !bundle.collections.every(isRegistration)) {
            throw new Error("collection declaration requires exact registrations");
        }
        const selected = new Set<string>();
        for (const collection of bundle.collections as NativeRegistration[]) {
            const original = (bundle.registrations as NativeRegistration[]).find((r) => r.resourceId === collection.resourceId);
            if (!original || canonicalJson(original) !== canonicalJson(collection) || collection.class !== "managed"
                || !collectionTypes.has(collection.pulumiType) || selected.has(collection.pulumiUrn)) {
                throw new Error("unsupported, duplicate or unowned cloud collection");
            }
            selected.add(collection.pulumiUrn);
        }
    }
    return bundle as unknown as CloudDeclarationBundle;
}

export function validateResourceRegistrations(declared: NativeRegistration[], observed: ObservedRegistration[]): void {
    const expected = new Map(declared.map((registration) => [registrationKey(registration.pulumiType, registration.pulumiName), registration]));
    const actual = new Map<string, ObservedRegistration>();
    for (const registration of observed) {
        const key = registrationKey(registration.pulumiType, registration.pulumiName);
        if (actual.has(key)) throw new Error(`duplicate native registration ${registration.pulumiType}::${registration.pulumiName}`);
        actual.set(key, registration);
    }
    const missing = [...expected.keys()].filter((key) => !actual.has(key));
    const unexpected = [...actual.keys()].filter((key) => !expected.has(key));
    if (missing.length > 0 || unexpected.length > 0) {
        throw new Error(`native registration parity failed; missing=${missing.join(",") || "none"}; unexpected=${unexpected.join(",") || "none"}`);
    }
}

// This finite protocol is also checked by the CLI before native preparation.
// Keep in parity with resource-collection-protocol.json and CloudCollection.
export const collectionTypes = new Set([
    "gcp:compute/address:Address",
    "gcp:compute/firewall:Firewall",
    "gcp:compute/instance:Instance",
    "gcp:compute/network:Network",
    "gcp:compute/subnetwork:Subnetwork",
    "gcp:dns/managedZone:ManagedZone",
    "gcp:dns/recordSet:RecordSet",
    "nagare:compute:NagareInstance",
    "nagare:env:NagareNixCache",
    "nagare:net:NagareNetwork"
]);
let omittedRegistrations = new Set<string>();

/** Omit only a reviewed registration. A protected/unknown type never reaches this set. */
export function shouldDeclareResource(type: string, name: string): boolean {
    return !omittedRegistrations.has(registrationKey(type, name));
}

export interface ResourceDeclarationGuard {
    readonly enabled: boolean;
    assertComplete(): void;
}

export function installResourceDeclarationGuard(path = process.env.NAGARE_RESOURCE_DECLARATIONS): ResourceDeclarationGuard {
    omittedRegistrations = new Set();
    if (!path) return { enabled: false, assertComplete: () => undefined };
    const bundle = decodeCloudDeclarationBundle(readFileSync(path, "utf8"));
    const declared = new Map(bundle.registrations.map((registration) => [registrationKey(registration.pulumiType, registration.pulumiName), registration]));
    omittedRegistrations = new Set((bundle.collections ?? []).map((r) => registrationKey(r.pulumiType, r.pulumiName)));
    const consumed = new Set<string>();

    pulumi.runtime.registerStackTransformation((args) => {
        const key = registrationKey(args.type, args.name);
        const registration = declared.get(key);
        if (!registration) {
            if (args.type.startsWith("gcp:") || args.type.startsWith("nagare:")) {
                throw new Error(`Pulumi registered undeclared resource ${args.type}::${args.name}`);
            }
            return undefined;
        }
        if (omittedRegistrations.has(key)) throw new Error(`collected resource was registered: ${args.type}::${args.name}`);
        consumed.add(key);
        return { props: args.props, opts: args.opts };
    });

    return {
        enabled: true,
        assertComplete: () => {
            const missing = [...declared.keys()].filter((key) => !consumed.has(key) && !omittedRegistrations.has(key));
            if (missing.length > 0) throw new Error(`declared Pulumi resources were not registered: ${missing.join(",")}`);
        },
    };
}
