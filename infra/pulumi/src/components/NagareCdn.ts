import * as pulumi from "@pulumi/pulumi";
import * as gcp from "@pulumi/gcp";

/**
 * MasterPlan 11 (CDN) / EP-56 — the STANDING Google Cloud CDN capability: a
 * Google global external Application Load Balancer (a worldwide anycast HTTP/
 * HTTPS front door) in front of the single VM `nagare-01`, with Cloud CDN
 * enabled. This component creates only the long-lived singleton infrastructure;
 * PER-SITE and PER-PATH cache rules are applied at deploy time by EP-58 via
 * `gcloud compute backend-services update` and URL-map path matchers — never by
 * `pulumi up` (MasterPlan Integration Point 2).
 *
 * The topology is the one EP-54 (the substrate spike) validated by hand:
 *   anycast IP -> forwarding rules (:80 redirect, :443) -> target proxies ->
 *   URL map -> CDN-enabled backend service -> unmanaged instance group (the VM).
 * The backend service preserves the client's original `Host` header (the Google
 * external ALB default), so Knative still routes by hostname through the LB.
 */
export interface NagareCdnArgs {
    gcpProject: string;
    region: string;
    zone: string;
    baseDomain: string;
    /** Self-link of the VM `nagare-01` (NagareInstance `this.instance.selfLink`). */
    instanceSelfLink: pulumi.Input<string>;
    /** VPC network id, for the unmanaged instance group. */
    network: pulumi.Input<string>;
    /** The VM's existing regional static IP, passed for reference/diagnostics. */
    publicIp: pulumi.Input<string>;
}

export class NagareCdn extends pulumi.ComponentResource {
    public readonly cdnGlobalIp: pulumi.Output<string>;
    public readonly cdnBackendService: pulumi.Output<string>;
    public readonly cdnUrlMap: pulumi.Output<string>;

    constructor(name: string, args: NagareCdnArgs, opts?: pulumi.ComponentResourceOptions) {
        super("nagare:cdn:NagareCdn", name, {}, opts);

        // 1. The anycast IPv4 the CDN-enabled hostnames resolve to. A global
        //    address is announced from every Google edge, so clients reach the
        //    nearest one. EP-58 writes a per-hostname Cloud DNS A record to it.
        const globalIp = new gcp.compute.GlobalAddress(`${name}-ip`, {}, { parent: this });

        // 2. Unmanaged zonal instance group wrapping the single VM, with named
        //    ports so the backend service can target http:80 / https:443. The
        //    VM is hand-built and stateful, so a managed instance group (which
        //    templates and autoscales identical VMs) is the wrong model — an
        //    unmanaged group lets a backend point at the one existing VM.
        const instanceGroup = new gcp.compute.InstanceGroup(`${name}-ig`, {
            zone: args.zone,
            network: args.network,
            instances: [args.instanceSelfLink],
            namedPorts: [
                { name: "http", port: 80 },
                { name: "https", port: 443 },
            ],
        }, { parent: this });

        // 3. Health check (EP-54). HTTP-first interim: probe Kourier on port 80.
        //    Kourier (the Knative ingress Envoy) routes by Host header and
        //    answers an unmatched Host with 404, so the probe carries the app
        //    Host header the backend serves. The exact healthy host/path is
        //    confirmed by EP-54's live leg once `nagare-01` is powered on; until
        //    then the backend may report UNHEALTHY (a deferred, VM-off concern).
        const healthCheck = new gcp.compute.HealthCheck(`${name}-hc`, {
            httpHealthCheck: {
                port: 80,
                requestPath: "/",
                host: args.baseDomain,
            },
            checkIntervalSec: 10,
            timeoutSec: 5,
            healthyThreshold: 2,
            unhealthyThreshold: 3,
        }, { parent: this });

        // 4. CDN-enabled backend service. HTTP-first origin (the platform serves
        //    HTTP today; HTTPS is a one-flip change once origin TLS is enabled —
        //    EP-54 origin-TLS decision). loadBalancingScheme EXTERNAL_MANAGED is
        //    the global external Application Load Balancer. The default cache
        //    policy is the STANDING one; EP-58 layers per-site/per-path rules on
        //    top with `gcloud compute backend-services update`.
        const backend = new gcp.compute.BackendService(`${name}-backend`, {
            protocol: "HTTP",
            portName: "http",
            loadBalancingScheme: "EXTERNAL_MANAGED",
            healthChecks: healthCheck.id,
            enableCdn: true,
            cdnPolicy: {
                cacheMode: "CACHE_ALL_STATIC",
                defaultTtl: 3600,
                clientTtl: 3600,
                maxTtl: 86400,
                // The cache key MUST include the host so different CDN-fronted
                // hostnames sharing this one backend never collide in the edge
                // cache (EP-54: "the cache key includes the host and path").
                cacheKeyPolicy: {
                    includeHost: true,
                    includeProtocol: true,
                    includeQueryString: true,
                },
            },
            backends: [{
                group: instanceGroup.selfLink,
                balancingMode: "UTILIZATION",
                capacityScaler: 1.0,
            }],
        }, { parent: this });

        // 5. URL map — minimal default route only, so EP-58 can add per-host path
        //    matchers at deploy time. The Google external ALB forwards the
        //    original Host header to the backend by default, so no Host rewrite
        //    is configured and Knative routing survives the LB.
        const urlMap = new gcp.compute.URLMap(`${name}-urlmap`, {
            defaultService: backend.selfLink,
        }, { parent: this });

        // 6. Edge TLS termination with a Google-managed certificate. This is the
        //    single-hostname path (EP-54's simpler option): the managed cert's
        //    domains are fixed at creation. For multiple CDN hostnames or a
        //    wildcard, migrate to Certificate Manager (gcp.certificatemanager.*),
        //    the wildcard path EP-54 also records. Until `baseDomain` is
        //    delegated and a hostname resolves to the anycast IP, the cert sits
        //    in PROVISIONING — expected and non-blocking (see Idempotence).
        const cert = new gcp.compute.ManagedSslCertificate(`${name}-cert`, {
            managed: {
                domains: [args.baseDomain],
            },
        }, { parent: this });

        const httpsProxy = new gcp.compute.TargetHttpsProxy(`${name}-https-proxy`, {
            urlMap: urlMap.id,
            sslCertificates: [cert.id],
        }, { parent: this });

        // 7. HTTP -> HTTPS redirect. A tiny separate URL map whose default action
        //    is a 301 to HTTPS, fronted by an HTTP target proxy.
        const redirectMap = new gcp.compute.URLMap(`${name}-redirect`, {
            defaultUrlRedirect: {
                httpsRedirect: true,
                stripQuery: false,
                redirectResponseCode: "MOVED_PERMANENTLY_DEFAULT",
            },
        }, { parent: this });

        const httpProxy = new gcp.compute.TargetHttpProxy(`${name}-http-proxy`, {
            urlMap: redirectMap.id,
        }, { parent: this });

        // 8. Front-end entry points bound to the anycast IP: :443 to the HTTPS
        //    proxy, :80 to the redirect proxy.
        new gcp.compute.GlobalForwardingRule(`${name}-fr-https`, {
            portRange: "443",
            loadBalancingScheme: "EXTERNAL_MANAGED",
            ipAddress: globalIp.address,
            target: httpsProxy.id,
        }, { parent: this });

        new gcp.compute.GlobalForwardingRule(`${name}-fr-http`, {
            portRange: "80",
            loadBalancingScheme: "EXTERNAL_MANAGED",
            ipAddress: globalIp.address,
            target: httpProxy.id,
        }, { parent: this });

        this.cdnGlobalIp = globalIp.address;
        this.cdnBackendService = backend.name;
        this.cdnUrlMap = urlMap.name;

        this.registerOutputs({
            cdnGlobalIp: this.cdnGlobalIp,
            cdnBackendService: this.cdnBackendService,
            cdnUrlMap: this.cdnUrlMap,
        });
    }
}
