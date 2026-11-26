import { createHash } from "node:crypto";
import * as pulumi from "@pulumi/pulumi";
import * as gcp from "@pulumi/gcp";
import { shouldDeclareResource } from "../resourceDeclarations";

// EP-284 (MasterPlan 39): the context's workload identity pool, through which a
// granted application workload reaches its own Google service account with no key.
//
// The provider trusts the k3s cluster's service-account issuer. nagarectl reads the
// issuer and its JWKS from the API server and derives `nagare:workloadIdentity`; the
// JWKS is uploaded, so Google never fetches the issuer and the issuer needs no public
// URL. A pod exchanges a projected Kubernetes token whose audience is
// `workloadIdentityAudience(...)` for a federated token, whose `google.subject` is the
// token's `sub`, `system:serviceaccount:NS:nagare-wl-WORKLOAD`. Each grant's account
// admits exactly that one subject (NagareAppBucket).
//
// The component exists only while the context has an app bucket.

export interface WorkloadIdentityConfig {
    issuer: string;
    jwks: { keys: Record<string, unknown>[] };
}

export interface NagareWorkloadIdentityArgs {
    gcpProject: string;
    projectNumber: pulumi.Input<string>;
    context: string;                      // the stack name, which is the context name
    config: WorkloadIdentityConfig;
}

// The provider's ID inside the pool, fixed.
export const workloadIdentityProviderId = "kubernetes";

// Pool IDs are per project and a project can hold several contexts, so the ID names the
// context: `nagare-<context>` when that is a valid pool ID (4..32 of [a-z0-9-], starting
// with a letter, not ending with `-`), else `nagare-` and the first 16 hex digits of the
// context's SHA-256.
export function workloadIdentityPoolId(context: string): string {
    const candidate = `nagare-${context}`;
    if (/^[a-z][a-z0-9-]{2,30}[a-z0-9]$/.test(candidate)) return candidate;
    return `nagare-${createHash("sha256").update(context, "utf8").digest("hex").slice(0, 16)}`;
}

// The provider's canonical resource name with the HTTPS prefix: the provider's one
// allowed audience, the audience of the projected token, and (without `https:`) the
// `audience` of the workload's external_account credential configuration.
export function workloadIdentityAudience(projectNumber: string, poolId: string): string {
    return `https://iam.googleapis.com/projects/${projectNumber}/locations/global/workloadIdentityPools/${poolId}/providers/${workloadIdentityProviderId}`;
}

// The one principal a grant's account admits.
export function workloadIdentityPrincipal(projectNumber: string, poolId: string, subject: string): string {
    return `principal://iam.googleapis.com/projects/${projectNumber}/locations/global/workloadIdentityPools/${poolId}/subject/${subject}`;
}

// The JWK fields Google accepts in an uploaded JWKS; any other field is dropped.
const jwkFields = ["kty", "alg", "use", "kid", "n", "e", "x", "y", "crv"];

// The derived config: an HTTPS issuer and a JWKS with at least one key.
export function parseWorkloadIdentity(raw: string | undefined): WorkloadIdentityConfig | undefined {
    if (raw === undefined || raw.trim() === "") return undefined;
    const parsed: unknown = JSON.parse(raw);
    const value = parsed as Record<string, unknown>;
    const jwks = value?.jwks as Record<string, unknown> | undefined;
    if (value === null || typeof value !== "object" || typeof value.issuer !== "string" || !/^https:\/\/[^\s]+$/.test(value.issuer)
        || jwks === null || typeof jwks !== "object" || !Array.isArray(jwks.keys) || jwks.keys.length === 0
        || !jwks.keys.every((key) => key !== null && typeof key === "object" && typeof (key as Record<string, unknown>).kty === "string")) {
        throw new Error("nagare:workloadIdentity needs an https issuer and a jwks with at least one key");
    }
    const keys = (jwks.keys as Record<string, unknown>[]).map((key) =>
        Object.fromEntries(jwkFields.filter((field) => key[field] !== undefined).map((field) => [field, key[field]])));
    return { issuer: value.issuer, jwks: { keys } };
}

// The JWKS as Google stores it. The provider re-serializes the uploaded JWKS in its own
// layout (protobuf JSON: two-space indent, `[{ ... }, { ... }]`) and reads it back so, so
// sending any other spelling of the same keys is a perpetual diff on `oidc.jwksJson`.
export function googleJwksJson(jwks: { keys: Record<string, unknown>[] }): string {
    const key = (k: Record<string, unknown>) =>
        Object.entries(k).map(([field, value]) => `    ${JSON.stringify(field)}: ${JSON.stringify(value)}`).join(",\n");
    return `{\n  "keys": [{\n${jwks.keys.map(key).join("\n  }, {\n")}\n  }]\n}`;
}

export class NagareWorkloadIdentity extends pulumi.ComponentResource {
    public readonly poolId: string;
    public readonly audience: pulumi.Output<string>;

    constructor(name: string, args: NagareWorkloadIdentityArgs, opts?: pulumi.ComponentResourceOptions) {
        super("nagare:env:NagareWorkloadIdentity", name, {}, opts);
        const declare = (type: string, suffix: string) => shouldDeclareResource(type, `${name}-${suffix}`);
        this.poolId = workloadIdentityPoolId(args.context);
        this.audience = pulumi.output(args.projectNumber).apply((number) => workloadIdentityAudience(number, this.poolId));

        const pool = declare("gcp:iam/workloadIdentityPool:WorkloadIdentityPool", "pool") ? new gcp.iam.WorkloadIdentityPool(`${name}-pool`, {
            project: args.gcpProject,
            workloadIdentityPoolId: this.poolId,
            displayName: "Nagare workloads",
            description: `Application workloads of the Nagare context ${args.context}`,
        }, { parent: this }) : undefined;

        if (declare("gcp:iam/workloadIdentityPoolProvider:WorkloadIdentityPoolProvider", "provider")) new gcp.iam.WorkloadIdentityPoolProvider(`${name}-provider`, {
            project: args.gcpProject,
            workloadIdentityPoolId: pool?.workloadIdentityPoolId ?? this.poolId,
            workloadIdentityPoolProviderId: workloadIdentityProviderId,
            displayName: "Nagare k3s service accounts",
            attributeMapping: { "google.subject": "assertion.sub" },
            oidc: {
                issuerUri: args.config.issuer,
                allowedAudiences: [this.audience],
                jwksJson: googleJwksJson(args.config.jwks),
            },
        }, { parent: this });

        this.registerOutputs({ audience: this.audience });
    }
}
