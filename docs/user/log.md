# Bundle Update Log

## 2026-09-26
* **Fix**: Complete reviewed task collection through the CLI using accepted private native bytes and the exact retained CronJob incarnation.
* **Update**: Save reviewed task deletion as successive CronJob suspension, member retention, and exact collection reviews; each stage requires apply.
* **Update**: Allow explicitly reviewed retention of one removed inventory member while its application scope and siblings remain accepted; collection remains a separate review.
* **Fix**: Require a named context for `nagared` and a shared inventory store for cloud webhook deployments.
* **Fix**: Refuse direct live CDN purge/disable and access grant/revoke/portal sync after inventory initialization; keep their read-only inspection paths.
* **Fix**: Refuse `nagared` webhook deployments after the selected context initializes inventory history, including when admission occurs after the webhook worker starts.
* **Fix**: Require accepted reviewed scopes for live app stop/restart and saved reviews for app deletion, site rollback, and preview deletion after inventory initialization.
* **Fix**: Require reviewed env and versioned Secret writes after inventory initialization, including newly named application stores.
* **Fix**: Refuse direct live database, broker, and volume data operations in initialized inventory contexts; keep reviewed create/restart/retirement and read-only previews available.
* **Fix**: Require stable-ID reviewed task runs after inventory initialization and refuse direct scheduled-task deletion there until reviewed retirement exists.
* **Fix**: Require reviewed live Service, worker, and site deploys after inventory initialization, including static previews; keep image-free offline rendering available.
* **Update**: Scope the first inventory-backed release to fresh contexts; label platform upgrade and rollback as legacy compatibility unavailable after inventory admission.
* **Fix**: Refuse direct aggregate app deploy after inventory history is initialized; use reviewed image publication and deployment even for a newly named app.
* **Update**: Document that direct host age-key placement and rotation close after resource inventory admission until a reviewed credential operation exists.
* **Fix**: Clarify that unnamed init also refuses cloud bootstrap for an explicitly selected context with admitted inventory history.
* **Fix**: Explain that context profile replacement, context deletion, and confirmed legacy cleanup refuse after substantive resource inventory admission.

## 2026-09-25
* **Update**: Document private inventory export and exact empty-store restore, and reconcile the completed GCS migration rehearsal with ADR 13.
* **Update**: Allow a separately named Pulumi node service account and opt out of shared project API ownership for an isolated second stack while preserving existing defaults.
* **Update**: Document checked global GitHub release publication, exact asset verification, draft recovery, immutable retry inputs, and the local completion observation.
* **Fix**: State that coarse platform upgrades refuse contexts with reviewed inventory history until component-backed upgrade and recovery are integrated.
* **Update**: Allow reviewed application, Service, and worker deployment of a separately published image when the typed config describes a Dockerfile or Nixpacks build.
* **Update**: Route accepted database and broker restarts through reviewed StatefulSet scope updates with optional saved plans while preserving data companions.
* **Fix**: Explain that direct portal sync refuses accepted or retained shared auth settings and uses reviewed application contributions for managed portals.
* **Update**: Document single-invocation reviewed application image publication and exact remote tag refusal.
* **Update**: Explain reviewed application and standalone Service stop/restart, the persisted cluster-local override, and explicit reviewed recovery.
* **Update**: Document reviewed Google CDN host DNS for applications and production sites, the accepted platform BackendService input, atomic exact-old updates, and uncertain recovery.
* **Update**: Document reviewed Google CDN site rollback with the same accepted backend binding and retained DNS declaration.
* **Fix**: Make direct Google CDN host DNS create-only after a successful exact-name read; refuse existing mismatched records and failed reads.
* **Fix**: Treat the Google CDN apex as a checked Pulumi-owned DNS reference, and refuse direct CDN or deploy writes to hostnames claimed by accepted or retained inventory.
* **Update**: Explain that Google CDN application deploys inherit the Pulumi-owned backend cache policy and refuse per-application overrides.
* **Update**: Document reviewed explicit Redpanda topic retention changes and conservative recovery after an uncertain update.
* **Update**: Document reviewed aggregate pre-deploy hooks, explicit affected resources, stable per-tag Jobs, and completion ordering before workloads.
* **Update**: Document opt-in single-invocation reviewed env set, delete, and merged or exact sync.
* **Update**: Document single-invocation reviewed Secret set, delete, and exact sync with opaque rotation versions.
* **Update**: Document single-invocation reviewed manual task runs with stable run IDs and the saved-review inspection option.

## 2026-09-24
* **Update**: Route reviewed application dry-run through the same typed scope compilation as saved planning; document its accepted inputs and redacted public output.
* **Update**: Explain canonical typed-config digests in reviewed application, Service, and worker scope revisions.
* **Fix**: Preserve stable reviewed Job identity when a valid task and run ID exceed the Kubernetes Job name limit together.
* **Update**: Allow reviewed one-off Jobs from accepted unlabeled CronJobs using the `-` app sentinel and exact label matching.
* **Fix**: Address co-located tasks by their deployed app ownership label even when the optional managed-environment association is unset.
* **Update**: Document reviewed one-off Task Job planning from accepted CronJob evidence, stable run IDs, and guarded Job collection.
* **Update**: Clarify that a changed direct database config still checks older retained backup and configuration addresses.
* **Update**: Document direct database and broker operation guards across retained companion addresses.
* **Update**: Document the direct server deploy guard for retained site PVC addresses.
* **Update**: Explain dependency-ordered preview collection and conditional deletion of delete-policy PVCs after their Service.
* **Update**: Document reviewed server preview PVC ownership, retained-volume recovery, and current PVC collection limit.
* **Update**: Document reviewed stateless server previews and their Runtime Secret dependencies.
* **Update**: Document exact adoption of existing direct static previews into their reviewed scope.
* **Update**: Document reviewed preview retirement followed by exact collection of its retained Service and DomainMapping.
* **Update**: Document reviewed static preview deployment with four accepted Runtime/Preview environment stores.
* **Update**: Document reviewed site rollback from accepted release history and an accepted image publication.
* **Update**: Document accepted supplied TLS Secret dependencies for reviewed static and server sites.
* **Update**: Document accepted runtime Secret dependencies for reviewed server sites and the remaining Build/Preview limit.
* **Update**: Document reviewed server-site PVC membership and required retained-volume recovery bindings.
* **Update**: Document supported reviewed server-site deployment and legacy import beside static sites, including stateless and Secret dependency limits.
* **Update**: Document exact reviewed import of existing static-site releases and live Service/domain ownership.
* **Update**: Document the supported reviewed static-site deployment path, accepted image and Namespace prerequisites, and remaining site variants.
* **Update**: Show only Secret identity and key names in direct dry-run output; keep plaintext and reversible base64 values out of public previews.
* **Update**: Document exact reviewed adoption of existing application and standalone Service release logs before subsequent reviewed deployment.
* **Update**: Clarify that reviewed app deploy refuses aggregate pre-deploy hooks while Service scheduled tasks join its review.
* **Update**: Document reviewed single-Service release history and its legacy import boundary.
* **Update**: Document reviewed application release history, accepted prior entries, and the legacy ConfigMap adoption requirement.
* **Update**: Document reviewed collection of retained central access DomainMappings with native preconditions.
* **Update**: Document reviewed protected Service and application routes through accepted auth owner contributions and central DomainMappings.
* **Update**: Document accepted topic bindings and verification dependencies in reviewed Service, worker, and application deployment.
* **Update**: Document reviewed Redpanda topic creation, retained topic claims, and conservative recovery of uncertain topic creation.
* **Update**: Document accepted standalone database dependencies and credential-template checks for reviewed web Service and worker deployment.
* **Update**: Document topic free accepted broker references in reviewed standalone web Service deployment.
* **Update**: Document topic free accepted broker bindings for reviewed standalone workers.
* **Update**: Document reviewed standalone worker deployment and retirement, accepted image and Namespace dependencies, and retained PVC recovery.
* **Update**: Document reviewed retirement of accepted standalone web Services through app delete.
* **Update**: Document versioned reviewed single-key Secret set and delete from accepted private history.
* **Update**: Document reviewed single-key environment set and delete from accepted channel history.
* **Update**: Document reviewed environment merge against accepted channel history.
* **Update**: Document reviewed application retirement, exact accepted-scope selection, and retained resources.
* **Update**: Document scheduled CronJobs in reviewed application deployment and the accepted-image requirement.
* **Update**: Document the reviewed single-Service deploy route, its scheduled CronJobs, and explicit image, recovery, and Secret dependencies.
* **Update**: Document the separate reviewed Build environment channel and its exact-replacement behavior.
* **Update**: Document the versioned reviewed Build Secret channel and its separate rotation history.
* **Update**: Document reviewed Preview environment and Secret overlays with their separate scope revisions.

## 2026-09-23
* **Update**: Document the opt-in shared inventory history store, conditional migration, explicit takeover, backup coverage, and bucket-reader access to private native reviews.
* **Update**: Clarify that legacy platform release adoption does not adopt provider objects into the managed resource inventory; those require a separate exact-incarnation review.

## 2026-09-15
* **Update**: Document the optional context-owned Attic provider, signed producer-to-Job flow, trust and secret boundaries, operations, rotation, recovery, and protected retirement.
* **Update**: Separate GCE instance, generated NixOS attribute, and logical Tailscale SSH identities in direct host switches and staged platform upgrades.

## 2026-09-14
* **Update**: Advance current installation and re-pin examples to 0.3.0; document the release's strict multi-domain, reviewed-infrastructure, context-safe bootstrap, and migration paths.
* **Update**: Make the canonical GCP onboarding sequence use reviewed-release and target placeholders, identify billable targets and observable success, and document boot-disk replacement versus online data-disk growth.
* **Update**: Document supported post-boot host age-key delivery over IAP.
* **Update**: Document opt-in public wildcard namespaces, self-signed internal issuer roles, payload-bundled patched net-certmanager delivery, certificate-policy verification, and reviewed stale-certificate cleanup.
* **Update**: Document context-bound reviewed Pulumi plans, guarded non-interactive apply and teardown, upgrade resume semantics, and explicit per-context image builders with named shared-project exceptions.
* **Update**: Document bundled Pulumi, separate Node.js and Google Cloud SDK prerequisites, the version --tools report, and the 0.2.2 installation pin.

## 2026-09-13
* **Update**: Document the context-owned Pulumi stack config and its workspace links, the npm dependency install for payload workspaces, the merging context create --force, the DNS zone and bucket replacement guard, and the guarded Pulumi phases of platform upgrade.
* **Update**: Add a resumable macOS runbook for trusting and removing the local CA and completing the three real-browser passkey ceremonies.
* **Update**: Document deploying, customizing, synchronizing, and safely removing an operator-owned authentication portal.
* **Update**: Document the context-owned VM shape, the in-place versus replacement matrix, and the infra-up replacement guard.

## 2026-09-12
* **Update**: Document growing the data disk: the preview to expect, the automatic grow on boot, the one-command online grow (systemctl restart, not start), that shrinking is impossible and when protect takes effect, that bootDiskSizeGb is create-time only, and the unsigned-path flag host-switch now passes to nix copy.
* **Update**: Make the ACME identity context-owned: document NAGARE\_ACME\_EMAIL and NAGARE\_ACME\_DIRECTORY across contexts, reference, onboarding and cluster bootstrap, including the no-default refusal, the staging rehearsal, and recovering an account registered under a wrong address.
* **Update**: Document the enforced project confinement: what keeps Nagare inside your project, the nagarectl context guard / context env commands, and the infra-up preflight.

## 2026-08-28
* **Migration**: Adopt the shared user-documentation profile and assign stable document handles.
