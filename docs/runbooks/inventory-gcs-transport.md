# GCS inventory transport

GCS inventory commands use the pinned Gogol SDK for object requests. They retain
one HTTP manager per opened store and use gcloud for credential acquisition and
the existing project/bucket ownership probes. No global gcloud or kubectl context
is switched. Local inventory stores are unaffected.

Journal reads enumerate the complete prefix and download exact object generations
with eight workers. Each available worker takes the next object immediately; a
slow response does not hold up a whole batch. An incomplete download refuses the
batch, and warm commands still validate the complete journal. The
[500-event cloud proof](../audits/mp23-archive/mp23-gcs-scale-proof.md) records the measured
limits and the scheduling regression that motivated this behavior.

Select the intended gcloud configuration/account using the existing process
settings before running a command, for example:

```bash
CLOUDSDK_ACTIVE_CONFIG_NAME=my-config CLOUDSDK_CORE_ACCOUNT=operator@example.com \
  nagarectl --context my-context inventory status --json
```

The inventory context's project must agree with the stored context and any
`CLOUDSDK_CORE_PROJECT` override. Nagare captures the selected gcloud account,
configuration and service-account impersonation setting and retains them through
token refresh. It does not discover Application Default Credentials or inspect
gcloud's credential database. Refresh is serialized across concurrent downloads;
a changed identity or invalid expiry stops the affected operation. A failed
refresh invalidates the session for the remainder of that command: waiting
downloads receive the same redacted failure instead of each spawning gcloud.
Check the selected gcloud credentials, then restart the command. Recover an
interrupted mutation through its original inventory transaction; do not create
a replacement review or assume a failed acknowledgement means no effect.

A provider 401 is a refusal, not an automatic credential refresh and HTTP retry.
If a write has landed but its acknowledgement/readback fails authentication,
its outcome remains unknown until the original transaction can reconcile it.

The credential bridge uses `gcloud config config-helper --format=json
--min-expiry=120s`, whose installed help documents its external-tool schema but
marks it as an internal interface that may change. Missing or malformed fields
fail before storage access. gcloud helper/ownership processes have a 15-second
bound; each SDK request, including credential preparation, has a 20-second bound.
These are request bounds, not a time limit for a whole migration or native apply.

Gogol's pinned credential API has no token-provider callback. Nagare loads a
short-lived SDK auth environment for each bounded request through a private
0600 temporary token file, removes that file immediately after SDK initialization,
and reuses the command's HTTP manager. Tokens are cached in memory against their
real expiry, with 60 seconds of margin. No background refresh process or persistent
token file is created. The SDK's 60-second token-file lifetime exceeds the entire
20-second request bound; long-running commands refresh through the captured
gcloud identity, not through the removed file.

The SDK path currently requires a named gcloud account/configuration, a token
with a usable expiry, and the `googleapis.com` universe. Normal account credentials
and configured service-account impersonation are supported through gcloud.
Credential/token file overrides, fixed access tokens, and custom Storage endpoints
other than the default or an explicit loopback emulator refuse early. To retain
the previous transport for such a configuration, select it explicitly:

```bash
NAGARE_INVENTORY_GCS_TRANSPORT=gcloud \
  nagarectl --context my-context inventory status --json
```

`NAGARE_INVENTORY_GCS_TRANSPORT=gogol` explicitly selects the default SDK path.
An unknown transport value refuses. There is no automatic fallback after an SDK
error: a failed or uncertain write must be resolved by the inventory protocol,
not retried through another transport. This switch changes no stored format and
requires no history migration.

Offline HTTP tests use `CLOUDSDK_API_ENDPOINT_OVERRIDES_STORAGE` with the exact
shape `http://127.0.0.1:<port>/storage/v1/` and synthetic credentials. Arbitrary
endpoint hosts are not accepted by the SDK path. An unset endpoint is captured as
`https://storage.googleapis.com/storage/v1/`; exporting an empty endpoint breaks
gcloud's bucket probe and is not equivalent to leaving the property unset.

The [CLI integration proof](../audits/mp23-archive/mp23-gogol-cli-proof.md) records correctness,
request counts, migration and read-only GCS evidence. Those results do not accept
MP-23's outstanding native/host/cloud mutation gates.
