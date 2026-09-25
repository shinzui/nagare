import * as pulumi from "@pulumi/pulumi";
import * as gcp from "@pulumi/gcp";
import {
    activatesCertificateMap,
    CdnCertificateMode,
    preparesCertificateMap,
    requireActiveCertificateState,
} from "../cdnCertificateMode";

/**
 * MasterPlan 11 (CDN) / EP-56 — the STANDING Google Cloud CDN capability: a
 * Google global external Application Load Balancer (a worldwide anycast HTTP/
 * HTTPS front door) in front of the single VM `nagare-01`, with Cloud CDN
 * enabled. This component owns the long-lived singleton infrastructure and
 * its shared cache policy. Application deployment does not update the backend.
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
    /** Platform Cloud DNS zone that owns baseDomain. */
    dnsZone: pulumi.Input<string>;
    /** Explicit staged migration state for the edge certificate. */
    certificateMode: CdnCertificateMode;
}

export class NagareCdn extends pulumi.ComponentResource {
    public readonly cdnGlobalIp: pulumi.Output<string>;
    public readonly cdnBackendService: pulumi.Output<string>;
    public readonly cdnUrlMap: pulumi.Output<string>;
    public readonly cdnCertificate: pulumi.Output<string>;
    public readonly cdnCertificateMap: pulumi.Output<string>;

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

        // 3. Health check. Kourier's listening socket is the standing backend
        //    invariant: it does not depend on an application route already
        //    owning the apex Host header. Route readiness is checked separately
        //    by nagarectl after each DomainMapping is applied.
        const healthCheck = new gcp.compute.HealthCheck(`${name}-hc`, {
            tcpHealthCheck: {
                port: 80,
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
        //    policy is the STANDING one for every hostname on this backend.
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

        // 5. URL map — a shared default route. The Google external ALB forwards the
        //    original Host header to the backend by default, so no Host rewrite
        //    is configured and Knative routing survives the LB.
        const urlMap = new gcp.compute.URLMap(`${name}-urlmap`, {
            defaultService: backend.selfLink,
        }, { parent: this });

        // 6. Keep the legacy certificate resource throughout the staged
        //    migration. `legacy` and `prepare` attach it to the proxy;
        //    `certificate-map` detaches it only after the operator has observed
        //    the replacement as ACTIVE and selected that mode explicitly.
        const legacyCert = new gcp.compute.ManagedSslCertificate(`${name}-cert`, {
            managed: {
                domains: [args.baseDomain],
            },
        }, { parent: this });

        let certificate: gcp.certificatemanager.Certificate | undefined;
        let certificateMap: gcp.certificatemanager.CertificateMap | undefined;
        if (preparesCertificateMap(args.certificateMode)) {
            const authorization = new gcp.certificatemanager.DnsAuthorization(`${name}-dns-auth`, {
                project: args.gcpProject,
                location: "global",
                domain: args.baseDomain,
                type: "FIXED_RECORD",
            }, { parent: this });

            const authorizationRecord = authorization.dnsResourceRecords.apply((records) => {
                if (records.length !== 1) {
                    throw new Error(`Certificate Manager returned ${records.length} DNS authorization records; expected one`);
                }
                return records[0];
            });
            new gcp.dns.RecordSet(`${name}-dns-auth-record`, {
                project: args.gcpProject,
                managedZone: args.dnsZone,
                name: authorizationRecord.apply((record) => record.name),
                type: authorizationRecord.apply((record) => record.type),
                ttl: 300,
                rrdatas: [authorizationRecord.apply((record) => record.data)],
            }, { parent: this });

            certificate = new gcp.certificatemanager.Certificate(`${name}-certificate`, {
                project: args.gcpProject,
                location: "global",
                scope: "DEFAULT",
                managed: {
                    domains: [args.baseDomain, `*.${args.baseDomain}`],
                    dnsAuthorizations: [authorization.id],
                },
            }, { parent: this });

            certificateMap = new gcp.certificatemanager.CertificateMap(`${name}-certificate-map`, {
                project: args.gcpProject,
            }, { parent: this });
            new gcp.certificatemanager.CertificateMapEntry(`${name}-certificate-map-apex`, {
                project: args.gcpProject,
                map: certificateMap.name,
                hostname: args.baseDomain,
                certificates: [certificate.id],
            }, { parent: certificateMap });
            new gcp.certificatemanager.CertificateMapEntry(`${name}-certificate-map-wildcard`, {
                project: args.gcpProject,
                map: certificateMap.name,
                hostname: `*.${args.baseDomain}`,
                certificates: [certificate.id],
            }, { parent: certificateMap });
        }

        let proxyCertificateArgs: {
            certificateMap?: pulumi.Input<string>;
            sslCertificates?: pulumi.Input<pulumi.Input<string>[]>;
        };
        if (activatesCertificateMap(args.certificateMode)) {
            const activeCertificateMap = certificate!.managed.apply((managed) => {
                requireActiveCertificateState(managed?.state);
                return certificateMap!.name;
            });
            proxyCertificateArgs = {
                certificateMap: pulumi.interpolate`//certificatemanager.googleapis.com/projects/${args.gcpProject}/locations/global/certificateMaps/${activeCertificateMap}`,
            };
        } else {
            proxyCertificateArgs = { sslCertificates: [legacyCert.id] };
        }
        const httpsProxy = new gcp.compute.TargetHttpsProxy(`${name}-https-proxy`, {
            urlMap: urlMap.id,
            ...proxyCertificateArgs,
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
        this.cdnCertificate = certificate?.name ?? pulumi.output("(legacy certificate)");
        this.cdnCertificateMap = certificateMap?.name ?? pulumi.output("(legacy certificate)");

        this.registerOutputs({
            cdnGlobalIp: this.cdnGlobalIp,
            cdnBackendService: this.cdnBackendService,
            cdnUrlMap: this.cdnUrlMap,
            cdnCertificate: this.cdnCertificate,
            cdnCertificateMap: this.cdnCertificateMap,
        });
    }
}
