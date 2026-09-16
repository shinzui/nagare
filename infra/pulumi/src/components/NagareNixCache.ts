import * as pulumi from "@pulumi/pulumi";
import * as gcp from "@pulumi/gcp";

export interface NagareNixCacheArgs {
    enabled: boolean;
    gcpProject: string;
    region: string;
    bucketName: string;
    serviceAccountEmail: pulumi.Input<string>;
}

/** Optional cloud storage and credential boundary for the in-cluster Attic cache. */
export class NagareNixCache extends pulumi.ComponentResource {
    public readonly enabled: pulumi.Output<boolean>;
    public readonly bucket: pulumi.Output<string>;
    public readonly hmacAccessId: pulumi.Output<string>;
    public readonly hmacSecret: pulumi.Output<string>;

    constructor(name: string, args: NagareNixCacheArgs, opts?: pulumi.ComponentResourceOptions) {
        super("nagare:env:NagareNixCache", name, {}, opts);

        this.enabled = pulumi.output(args.enabled);

        if (args.enabled) {
            const bucket = new gcp.storage.Bucket(`${name}-bucket`, {
                name: args.bucketName,
                location: args.region.toUpperCase(),
                uniformBucketLevelAccess: true,
                publicAccessPrevention: "enforced",
                forceDestroy: false,
            }, { parent: this, protect: true });

            new gcp.storage.BucketIAMMember(`${name}-bucket-iam`, {
                bucket: bucket.name,
                role: "roles/storage.objectAdmin",
                member: pulumi.interpolate`serviceAccount:${args.serviceAccountEmail}`,
            }, { parent: this });

            const hmac = new gcp.storage.HmacKey(`${name}-hmac`, {
                project: args.gcpProject,
                serviceAccountEmail: args.serviceAccountEmail,
            }, { parent: this, protect: true });

            this.bucket = bucket.name;
            this.hmacAccessId = hmac.accessId;
            // The provider already marks this additional output secret; wrap it
            // explicitly so mocks and any future provider regression preserve
            // the stack-output confidentiality boundary too.
            this.hmacSecret = pulumi.secret(hmac.secret);
        } else {
            this.bucket = pulumi.output("");
            this.hmacAccessId = pulumi.output("");
            this.hmacSecret = pulumi.secret("");
        }

        this.registerOutputs({
            enabled: this.enabled,
            bucket: this.bucket,
            hmacAccessId: this.hmacAccessId,
            hmacSecret: this.hmacSecret,
        });
    }
}
