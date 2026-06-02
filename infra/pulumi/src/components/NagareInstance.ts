import * as pulumi from "@pulumi/pulumi";
import * as gcp from "@pulumi/gcp";

export interface NagareInstanceArgs {
    zone: string;
    machineType: string;
    /** Self-link of the registered NixOS GCE image (Pulumi config key
     *  `nagareImageSelfLink`, written by EP-3's scripts/upload-images.sh). */
    imageSelfLink: string;
    subnetId: pulumi.Input<string>;
    /** The reserved static external IP address (string form). */
    publicIp: pulumi.Input<string>;
    /** The persistent data disk to attach (its self-link/id). */
    dataDiskId: pulumi.Input<string>;
    serviceAccountEmail: pulumi.Input<string>;
}

export class NagareInstance extends pulumi.ComponentResource {
    public readonly instance: gcp.compute.Instance;

    constructor(name: string, args: NagareInstanceArgs, opts?: pulumi.ComponentResourceOptions) {
        super("nagare:compute:NagareInstance", name, {}, opts);

        this.instance = new gcp.compute.Instance(name, {
            name,                       // GCE instance name == resource name == "nagare-01"
            zone: args.zone,
            machineType: args.machineType,
            bootDisk: { initializeParams: { image: args.imageSelfLink } },
            attachedDisks: [{
                source: args.dataDiskId,
                deviceName: "nagare-data",   // stable device name EP-3 mounts at /var/lib/nagare
                mode: "READ_WRITE",
            }],
            networkInterfaces: [{
                subnetwork: args.subnetId,
                // Assign the reserved static external IP so the VM is
                // reachable at a fixed, DNS-able address.
                accessConfigs: [{ natIp: args.publicIp }],
            }],
            serviceAccount: {
                email: args.serviceAccountEmail,
                // cloud-platform is the modern catch-all scope; real
                // authorization comes from the IAM roles granted to this
                // service account in NagarePerimeter, not from scopes.
                scopes: ["cloud-platform"],
            },
            // OS Login lets IAM control SSH access via the IAP tunnel.
            metadata: { "enable-oslogin": "TRUE" },
            // The data disk must survive the VM. Leave it out of the
            // instance lifecycle: it is its own gcp.compute.Disk resource.
        }, { parent: this });

        this.registerOutputs({});
    }
}
