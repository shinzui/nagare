# Managed resource mutation coverage

This catalogue records how a supported mutation family reaches the typed resource
inventory. It is an audit aid, not a declaration source: executable scope members,
reviewed operations, retained native bundles, and journal receipts remain the
authority.

Each row names the lifecycle-owning scope, declaration compiler, native executor,
focused evidence, delegated work, and disposition of the older entry point. A row
is `migrated` only when the public entry point uses the shared planner/executor and
the retained transport refuses an unscoped or foreign adapter child. `adapter-ready`
means the typed adapter exists but production command registration is still open.
EP-147 and EP-148 extend this table; EP-150 owns the final completeness audit.

| Mutation family | Owner scope | Declaration compiler | Executor / retained transport | Test evidence | Delegation | Legacy disposition | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Pulumi cloud stack preview/apply, including APIs, IAM, network, disks, buckets, DNS/CDN, registry, VM, and cache resources | platform cloud foundation | `Nagare.Inventory.Cloud.compileCloudScope`; `infra/pulumi/src/resourceDeclarations.ts` consumes the canonical registration bundle | `Nagare.Inventory.Adapters.Pulumi` + `PulumiRuntime`; exact Pulumi saved plan | `InventoryCloudSpec` records preparation/apply/verification and physical observation; `infra/pulumi/test/resourceInventory.test.ts`; existing reviewed-plan guard fixtures | Pulumi provider bookkeeping is explicitly classified in the native registration bundle | `infra preview --inventory` plans through the shared executor; `infra apply` auto-detects inventory reviews; resume reconstructs the runtime. The no-`--inventory` compatibility path remains until production declaration generation and upgrade callers migrate | migrated-with-compatibility |
| Guarded NixOS activation | platform host | `Nagare.Inventory.Host.compileHostScope` | `Nagare.Inventory.Adapters.Host` + `HostRuntime`; `scripts/inventory-host-transport.sh`; self-reverting activation transport | `InventoryHostSpec`; `nix/checks/scripts/test-host-switch-identity.sh`; host auto-rollback VM check | Nix derivations/files remain internal to the host executor; preparation retains the evaluated closure | Typed inventory plan/apply/resume use the production runtime; upgrade/`just host-switch` compatibility routing remains EP-150 work | migrated-with-compatibility |
| VM start/stop | platform host | Host resource bundle (physical instance dependency and explicit operation are still to be added) | Host adapter; `scripts/vm-power.sh` | `scripts/test-inventory-transport-guards.sh`; existing project-confinement checks | GCE performs the power transition | Transport rejects a foreign inventory child; public recipes remain legacy | adapter-ready |
| NixOS image object and GCE image publication | platform artifacts | `Nagare.Inventory.Artifact.compileArtifactScope` | `Nagare.Inventory.Adapters.Artifact` + `ArtifactRuntime`; `scripts/inventory-artifact-transport.sh` | `InventoryArtifactSpec`; `scripts/test-upload-images.sh`; bucket ownership guard | Nix build and builder-side upload are bounded transport; Pulumi owns the destination bucket | Typed inventory plan/apply/resume require the reviewed destination/content digest; direct publication remains an EP-150 compatibility path | migrated-with-compatibility |
| Temporary/on-demand Nix builder setup and lifecycle | platform artifacts | Artifact resource bundle | Artifact adapter; `scripts/setup-nix-builder.sh` and builder proxy/power transport | `scripts/test-inventory-transport-guards.sh`; builder confinement assertions in `scripts/test-upload-images.sh` | Idle shutdown and IAP proxying remain delegated to the builder | Setup transport rejects a foreign inventory child; direct setup and proxy-triggered power remain legacy | adapter-ready |
| Attic/Nix cache OCI image publication | platform artifacts | Artifact resource bundle | Artifact runtime; `scripts/inventory-artifact-transport.sh`; bounded publisher | `InventoryArtifactSpec`; `scripts/test-inventory-transport-guards.sh`; immutable pin/digest checks in the publisher | Registry authentication and copy are bounded transport | Reviewed inventory execution is registered; cluster bootstrap direct invocation remains EP-150 compatibility | migrated-with-compatibility |
| Context image/state bucket and API bootstrap | platform cloud foundation | Cloud resource bundle plus explicit bootstrap operation | Pulumi adapter after reviewed local bootstrap; store migration is owned by EP-151 | Bucket ownership guard; Pulumi registration parity | GCS conditional history migration belongs to EP-151 | `nagarectl init` still performs pre-inventory bootstrap; it must not be removed before the first-context local transaction exists | adapter-ready |
| Global release payload publication | dedicated release-publication scope | Artifact external-reference types only in deployment contexts | GitHub release adapter owned by EP-150 | To be supplied by EP-150 | Consuming contexts hold external references and never own publication | Not migrated by EP-146 | planned |

## Adapter-child boundary

The executor exports both `NAGARE_INVENTORY_TRANSACTION` and the closed executor
token in `NAGARE_INVENTORY_ADAPTER_CHILD` for execute, verify, and recovery calls,
then restores the caller's environment. Retained cloud/host/artifact transports
check the token before context resolution or provider work. A nested inventory
command sees the transaction marker and refuses, preventing self-deadlock on the
context lock. `scripts/test-inventory-transport-guards.sh` covers the early shell
boundary, while `InventoryTransactionSpec` covers marker scope and lock re-entry.
