# Config reference

> **Status:** ✅ **Built and tested** (the `nagare-dsl` library; 63 tests
> including negative type tests and QuickCheck properties). This is the field
> and constructor catalogue for the typed deployment config you write in
> `nagare/Config.hs`. For the deploy *workflow* and `nagarectl` commands, see
> [Deploying apps](deploying-apps.md).

A Nagare deployment is a single Haskell value of type `Deployment`, assembled
through **smart constructors** that make illegal configurations unrepresentable.
The design rule: every constrained field is a newtype whose data constructor is
hidden, exposed only through a validating `mkX :: ... -> Either Text X`. Code in
your `Config.hs` therefore *cannot* hold a bad value — a non-DNS name, an
out-of-range port, a malformed quantity, a `max < min` scale — without first
handling the `Left`.

All of this lives in the `nagare-dsl` library:

| Module | What it gives you |
| --- | --- |
| `Nagare.Dsl.Types` | The `Deployment` type, every field type, and their `mk*` constructors. |
| `Nagare.Dsl.Build` | The `build` field's `BuildSpec` modes and the `Tag` type / `mkTag`. |
| `Nagare.Dsl.Presets` | Reusable building blocks: `webService`, overlays, helpers. |
| `Nagare.Dsl.Config` | `emitDeployment` — the last line of your config's `main`. |

---

## The `Deployment` record

```haskell
data Deployment = Deployment
  { name        :: ServiceName              -- required
  , namespace   :: Namespace                -- required (use defaultNamespace for "personal")
  , image       :: ImageRef                 -- required, no tag (the tag is added at deploy time)
  , build       :: BuildSpec                -- required: how the image is produced (see Build modes)
  , domains     :: [DomainSpec]             -- public hostnames ([] = none); exactly one canonical
  , port        :: Port                     -- container port (defaultPort = 8080)
  , env         :: Map EnvName ScopedEnvVar -- environment variables (Map.empty for none)
  , resources   :: Maybe Resources          -- CPU/memory requests and limits (Nothing = omit)
  , scale       :: Maybe Scale              -- autoscaling bounds (Nothing = omit)
  , healthCheck :: Maybe HealthCheck         -- optional HTTP probe (Nothing = omit)
  , volumes     :: [Volume]                  -- durable disks ([] = stateless); see Volumes
  , databases   :: [DatabaseName]            -- managed databases this app uses ([] = none); see below
  }
```

> `webService` populates `build` with a default Dockerfile build, so preset-based
> configs need not mention it. A hand-written record literal must set `build` —
> see [Build modes](#build-modes) and the [migration note](build-modes.md). It
> must also set `domains` (use `[]` for none) and `healthCheck` (use `Nothing`).

> **`env` values carry scopes.** Each env value is a `ScopedEnvVar` — an `EnvVar`
> (literal or secret reference) plus the set of scopes it applies to. A bare
> variable is `runtimeScoped (EnvLiteral …)` (runtime only); see
> [Environment and secrets](env-and-secrets.md) for build/preview scopes.

Fields are strict and **unprefixed** — `name`, not `depName`. You build a
`Deployment` with a record literal after constructing each field through its
smart constructor (there is no hidden constructor for the record itself; the
safety comes from the field *types*).

## Field types and constructors

Every `mk*` returns `Either Text` — `Left` carries a precise, human-readable
message; `Right` carries the validated value.

### `ServiceName` — the Knative Service name

```haskell
mkServiceName :: Text -> Either Text ServiceName
serviceNameText :: ServiceName -> Text
```

A DNS-safe RFC 1123 label: **1–63 characters**, lowercase letters, digits, and
hyphens, **not starting or ending with a hyphen**. Rejected: empty, too long,
leading/trailing `-`, uppercase, or any other character.

### `Namespace`

```haskell
mkNamespace      :: Text -> Either Text Namespace
defaultNamespace :: Namespace          -- "personal"
namespaceText    :: Namespace -> Text
```

Same rules as `ServiceName`. Use `defaultNamespace` for the standard `personal`
namespace.

### `ImageRef` — the container image, **without a tag**

```haskell
mkImageRef  :: Text -> Either Text ImageRef
imageRefText :: ImageRef -> Text
```

Non-empty and **must not contain a colon** — the tag is appended separately at
deploy time (`nagarectl` computes a UTC timestamp tag, or you pass `--tag`).

You now supply only the app's **image name**, not the full registry path. Write
`mkImageRef "notes"` (or pass the bare name as `webService`'s second argument). At
deploy time `nagarectl` derives the registry prefix from your target profile —
`<NAGARE_REGISTRY_HOST>/<CLOUDSDK_CORE_PROJECT>/<NAGARE_ARTIFACT_REGISTRY_ID>` — and
prefixes the bare name, so the pushed/pulled image is e.g.
`us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes` for the default-example target. A
name that already contains a `/` (e.g. a public image like
`gcr.io/knative-samples/helloworld-go`) is treated as fully qualified and left
untouched.

```haskell
-- before (project + region baked into application source):
mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes"
-- after (just the name; the prefix comes from the target profile at deploy time):
mkImageRef "notes"
```

See [MasterPlan 12](../masterplans/12-bring-your-own-gcp-project-onboarding-for-nagare.md)
Integration Point 4 (the registry-host derivation) and EP-62 for the mechanism.

### `Port`

```haskell
mkPort      :: Int -> Either Text Port
defaultPort :: Port                    -- 8080
portInt     :: Port -> Int
```

A TCP port in **1–65535**. `defaultPort` is `8080`.

### `Quantity` — Kubernetes CPU/memory quantities

```haskell
mkQuantity   :: Text -> Either Text Quantity
quantityText :: Quantity -> Text
```

A digit run, an optional `.fraction`, then an optional recognised suffix:
`m k M G T P E Ki Mi Gi Ti Pi Ei`. Examples: `"250m"`, `"512Mi"`, `"1"`,
`"2Gi"`. Rejected: empty, not starting with a digit, or an unknown suffix.

### `EnvName` and `SecretName`

```haskell
mkEnvName     :: Text -> Either Text EnvName
mkSecretName  :: Text -> Either Text SecretName
envNameText   :: EnvName -> Text
secretNameText :: SecretName -> Text
```

Both must be non-empty.

### `EnvVar` — the headline safety invariant

```haskell
data EnvVar
  = EnvLiteral Text         -- rendered as `value: <text>`
  | EnvSecretRef SecretName -- rendered as valueFrom.secretKeyRef
```

An environment value is **either** a literal **or** a secret reference, never
both. In YAML you could write a single entry with both a `value:` and a
`secretRef:` key, producing an invalid manifest; modelling this as a sum type
makes that simply impossible to express. A `SecretRef` renders
`valueFrom.secretKeyRef` with `name` = the secret and `key` = the env var's own
name.

Build the `env` map directly, e.g.:

```haskell
import Data.Map.Strict qualified as Map

env = Map.fromList
  [ (literalVar, EnvLiteral "production")
  , (secretVar,  EnvSecretRef dbSecret)
  ]
```

…where `literalVar`, `secretVar` came from `mkEnvName` and `dbSecret` from
`mkSecretName`. (The `secretEnv` preset helper, below, does this in one call.)

### `Resources` — requests and limits

```haskell
data Resources = Resources
  { cpu         :: Maybe Quantity   -- request: guaranteed CPU
  , memory      :: Maybe Quantity   -- request: guaranteed memory
  , cpuLimit    :: Maybe Quantity   -- limit: CPU ceiling (Nothing = no limit)
  , memoryLimit :: Maybe Quantity   -- limit: memory ceiling (Nothing = no limit)
  }
```

A plain record (no smart constructor) — but every field is `Quantity`, so the
only way to populate them is through `mkQuantity`. **Requests** (`cpu`/`memory`)
are what the pod is scheduled against — the guaranteed amount; **limits**
(`cpuLimit`/`memoryLimit`) are the ceiling the container may not exceed. The
renderer emits a `requests:` sub-block and/or a `limits:` sub-block only for the
quantities present, e.g.:

```yaml
        resources:
          requests:
            cpu: 250m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
```

Set the whole `resources` field to `Nothing` on the `Deployment` to omit the
block entirely. The `webService` preset sets requests only (250m / 128Mi) with
both limits `Nothing`; add limits by overwriting the field:

```haskell
res = Resources
  { cpu = Just c250m, memory = Just m128, cpuLimit = Just c500m, memoryLimit = Just m512 }
```

### `HealthCheck` — an HTTP probe

```haskell
data HealthScheme = HTTP | HTTPS

data HealthCheck = HealthCheck
  { path             :: Text        -- non-empty, must start with "/"
  , checkPort        :: Maybe Port  -- Nothing = the container port
  , scheme           :: HealthScheme
  , expectedStatus   :: Int         -- documentation-only (see note); default 200
  , initialDelay     :: Int         -- seconds before the first probe (>= 0)
  , period           :: Int         -- seconds between probes (>= 1)
  , timeout          :: Int         -- per-probe timeout seconds (>= 1)
  , failureThreshold :: Int         -- consecutive failures before unhealthy (>= 1)
  , asLiveness       :: Bool        -- also emit a livenessProbe
  , asStartup        :: Bool        -- also emit a startupProbe
  }

mkHealthCheck   :: HealthCheck -> Either Text HealthCheck   -- validates an assembled value
httpHealthCheck :: Text -> Either Text HealthCheck          -- a path + sensible defaults
```

A `HealthCheck` is always rendered as a Knative `readinessProbe`, and
additionally as a `livenessProbe`/`startupProbe` when `asLiveness`/`asStartup`
are set. The quick path is `httpHealthCheck "/healthz"`, which fills `scheme =
HTTP`, `expectedStatus = 200`, `initialDelay = 0`, `period = 10`, `timeout = 1`,
`failureThreshold = 3`, and both `asLiveness`/`asStartup` `False`. Promote it to
all three probes by overwriting the two flags:

```haskell
do base <- httpHealthCheck "/healthz"
   pure base {asLiveness = True, asStartup = True}
```

For full control, assemble the record yourself and validate with `mkHealthCheck`
(it rejects an empty/relative path, an `expectedStatus` outside 100–599, a
negative `initialDelay`, or a `period`/`timeout`/`failureThreshold` below 1).

> **`expectedStatus` is documentation-only.** Knative's `httpGet` probe treats any
> 2xx/3xx as healthy and does not assert a specific status code, so this field is
> retained in the model for clarity and future use but is deliberately *not*
> rendered into the manifest.

### `Scale` — autoscaling bounds

```haskell
data Scale = Scale { minScale :: Int, maxScale :: Int }
mkScale :: Int -> Int -> Either Text Scale   -- mkScale min max
```

`mkScale` rejects negative values and requires `min <= max`. `minScale = 0`
means **scale to zero** when idle. Always build a `Scale` with `mkScale`;
constructing the record directly bypasses the check.

### `Domain` and `DomainSpec` — public hostnames

```haskell
mkDomain   :: Text -> Either Text Domain
domainText :: Domain -> Text

data DomainSpec = DomainSpec { domain :: Domain, canonical :: Bool }

mkDomains       :: [(Text, Bool)] -> Either Text [DomainSpec]
canonicalDomain :: [DomainSpec] -> Maybe Domain
```

A `Domain` is non-empty, no spaces, and no URI scheme (`http://`/`https://`). A
`Deployment` carries a *list* of domains (`domains :: [DomainSpec]`), each paired
with a `canonical` flag. Build the list with `mkDomains`, passing
`(hostname, isCanonical)` pairs:

```haskell
mkDomains [("app.example.com", True), ("www.example.com", False)]
```

- An **empty list** means "no custom domain" — the app is reached at its
  automatic `name.namespace.<baseDomain>` URL.
- A **non-empty list** must mark **exactly one** entry `canonical` (`mkDomains`
  rejects zero or two-plus canonicals). The canonical domain is the one
  `nagarectl` prints as the app's URL.
- The renderer emits **one `DomainMapping` per domain**, so every hostname routes
  to the Service.

> **Redirects are not installed.** Each domain gets a DomainMapping and the
> canonical one drives the reported URL, but a non-canonical hostname is *not*
> HTTP-redirected to the canonical one — that hard redirect remains deferred
> future work. All listed domains serve the app directly.

## Build modes

The `build` field (type `BuildSpec`, from `Nagare.Dsl.Build`) says **how** the
container image at `image` is produced. The repository path is always the
`Deployment`'s `image`; the mode only says what — if anything — to build and which
tag to deploy. For a full walkthrough with copyable configs, see
**[Build modes](build-modes.md)**.

```haskell
data BuildSpec
  = PrebuiltImage Tag                        -- deploy an existing image; build nothing
  | DockerfileBuild                          -- docker build from a Dockerfile, then push
      { dockerfile :: FilePathText
      , context    :: FilePathText
      , buildArgs  :: Map Text Text
      }
  | NixpacksBuild                            -- nixpacks build from source (no Dockerfile), then push
      { context   :: FilePathText
      , buildArgs :: Map Text Text
      }
```

| Constructor | Builds? | Fields |
| --- | --- | --- |
| `PrebuiltImage tag` | No | `tag :: Tag` — the tag to deploy (the cluster sees `image:tag`). |
| `DockerfileBuild {dockerfile, context, buildArgs}` | Yes | Dockerfile path, build context, and `--build-arg`s. |
| `NixpacksBuild {context, buildArgs}` | Yes | Build context and build-time env vars (`--env`). |

### `Tag` — a Docker image tag

```haskell
mkTag   :: Text -> Either Text Tag
tagText :: Tag -> Text
```

1–128 characters from `[A-Za-z0-9_.-]`, not starting with `.` or `-`, no
whitespace. Digests (`@sha256:...`) are out of scope. Used by `PrebuiltImage`.

### `FilePathText` — a relative project path

```haskell
mkFilePathText :: Text -> Either Text FilePathText   -- from Nagare.Dsl.Path
filePathText   :: FilePathText -> Text
```

A relative path inside the project (a build context like `"."`, a Dockerfile path
like `"docker/Dockerfile"`). Rejects empty, absolute (leading `/`), and
`..`-escaping paths. Re-exported from `Nagare.Dsl.Static.Types` as well.

### `defaultBuild` — the historical default

```haskell
defaultBuild :: Either Text BuildSpec   -- from Nagare.Dsl.Build
```

A `DockerfileBuild` with `dockerfile = "Dockerfile"`, `context = "."`, and no
build args — exactly Nagare's pre-`BuildSpec` behavior. `webService` uses this, so
a preset-based config already has it. Use it in a hand-written literal to keep the
old behavior: `build <- defaultBuild` (in an `Either` block).

## Volumes

`volumes :: [Volume]` attaches durable disks to an app. It defaults to `[]` (so
existing configs are unaffected — a stateless app has no volumes). Each `Volume`
renders one `PersistentVolumeClaim` plus a container `volumeMount` and pod
`volume`; see [Persistent storage](persistent-storage.md) for the full feature.

| Field | Type | Meaning |
| --- | --- | --- |
| `volName` | `VolumeName` (via `mkVolumeName`) | DNS-label name, unique within the app. |
| `size` | `Quantity` (via `mkQuantity`, e.g. `"1Gi"`) | Requested disk size. |
| `mountPath` | `MountPath` (via `mkMountPath`) | Absolute in-container path; unique within the app. |
| `accessMode` | `AccessMode` | `ReadWriteOnce` (single-node default). |
| `readOnly` | `Bool` | Mount the volume read-only. |
| `retention` | `RetentionPolicy` | `Retain` (keep on app deletion, backup-included) or `Delete` (destroy on deletion, backup-excluded). |

Name and mount-path uniqueness across an app's volumes is checked at load time;
a duplicate name or path is a `MarshalError "volumes"`. The ergonomic way to add
a `Retain` volume is the `attachVolume` overlay from `Nagare.Dsl.Presets`:

```haskell
import Nagare.Dsl.Presets (attachVolume, webService)

deployment =
  webService "notes" "gcr.io/myproject/notes"
    >>= attachVolume "data" "1Gi" "/data"   -- name size mountPath; Retain, RWO, rw
```

For a backup-excluded (`Delete`) volume, build the `Volume` record literal
directly (`Volume(..)`, `mkVolumeName`, `mkQuantity`, `mkMountPath` are exported
from `Nagare.Dsl.Types`) and set `retention = Delete`, then
`pure base { volumes = [v] }`. Attaching any volume pins the Service to
`min-scale = 1` / `max-scale = 1` / `rollout-duration = 0s` (single-writer +
stay-warm; see [Persistent storage](persistent-storage.md)).

## Managed databases

A **managed database** is a separate typed resource — not a `Deployment` field —
declared as a `Database` value and emitted with `emitDatabase` (the database
analogue of `emitDeployment`). It is provisioned and operated with the
`nagarectl db` command group, not `nagarectl deploy`. See
[Managed databases](managed-databases.md) for the full feature.

```haskell
data Engine = Postgres | Redis | ClickHouse

data Database = Database
  { dbName    :: DatabaseName       -- DNS-label name, unique in the namespace
  , engine    :: Engine             -- Postgres | Redis | ClickHouse
  , version   :: EngineVersion      -- pinned image tag (mkEngineVersion eng "18"); no "latest"
  , namespace :: Namespace          -- reuses the Deployment namespace type ("personal" default)
  , size      :: Quantity           -- data PVC size, e.g. mkQuantity "10Gi"
  , resources :: Maybe Resources    -- container CPU/memory; set a memory limit for ClickHouse
  , retention :: RetentionPolicy    -- Retain (keep the disk on delete) | Delete
  }
```

| Field type | Constructor | Notes |
| --- | --- | --- |
| `DatabaseName` | `mkDatabaseName :: Text -> Either Text DatabaseName` | DNS-1123 label (same rules as `ServiceName`). Exported from `Nagare.Dsl.Database` (and re-exported there from `Nagare.Dsl.Types`). |
| `Engine` | constructors `Postgres`/`Redis`/`ClickHouse` | `defaultEngineVersion` gives the modern major per engine (Postgres `18`, Redis `8`, ClickHouse `25.8`). |
| `EngineVersion` | `mkEngineVersion :: Engine -> Text -> Either Text EngineVersion` | Rejects empty, `latest`, and `:`-bearing tags; ClickHouse's `YY.M` form is accepted. |

`namespace`, `size`, `resources`, and `retention` reuse the same types as the
app model (above). The generated password is **not** in this config — it is
created by `nagarectl db create` and stored only in the managed Secret
`nagare-db-<name>`.

An app references databases by name through the `databases :: [DatabaseName]`
field on `Deployment` (above). At deploy time the app receives the per-engine
connection env — host/port/user/db as literals and the composed `*_URL`/password
as Secret references; the exact variables are in
[Managed databases](managed-databases.md#connecting-an-app-to-a-database).

## Reusable presets

`Nagare.Dsl.Presets` lets two apps share one definition. The pattern: start from
a base preset, then thread it through overlays with `do`/`=<<`.

```haskell
webService   :: Text -> Text -> Either Text Deployment
development  :: Deployment -> Either Text Deployment
production   :: Deployment -> Either Text Deployment
secretEnv    :: Text -> Text -> Deployment -> Either Text Deployment
stdResources :: Either Text Resources
teamDefaults :: Deployment -> Deployment
```

| Building block | Effect |
| --- | --- |
| `webService name image` | A standard HTTP service: namespace `personal`, port `8080`, scale `0..3`, `stdResources` (250m / 128Mi requests, no limits), no env, no domains, no health check. |
| `development dep` | Overlay → scale `0..1` (still scale-to-zero, at most one replica). |
| `production dep` | Overlay → scale `1..5` (always-warm) and larger resources (500m / 256Mi). |
| `secretEnv var secret dep` | Adds a `EnvSecretRef` env var, preserving existing entries. |
| `stdResources` | The 250m / 128Mi resource block. |
| `teamDefaults dep` | Pins namespace `personal` and clears any custom domains. (Pure — returns `Deployment`, not `Either`.) |

Every overlay is `Deployment -> Either Text Deployment` and routes any
constrained field it touches back through a smart constructor, so composing
valid presets always yields a valid `Deployment` — a property the library proves
with QuickCheck. Example composition (two apps, one shared definition):

```haskell
-- app A
deployment = production =<< webService "notes" "gcr.io/myproject/notes"

-- app B — same preset + overlay, plus a secret
deployment = do
  base   <- webService "tasks" "gcr.io/myproject/tasks"
  withDb <- secretEnv "DATABASE_URL" "tasks-db" base
  production withDb
```

## Emitting the value: `Nagare.Dsl.Config`

```haskell
emitDeployment :: Deployment -> IO ()
```

Call this as the last action of your config's `main`. It serialises the
already-validated `Deployment` to JSON on stdout; `nagarectl` reads that JSON
back and **re-runs every smart constructor** as defence in depth. The canonical
`main`:

```haskell
main :: IO ()
main = case deployment of
  Left err  -> ioError (userError err)   -- a constructor rejected something
  Right dep -> emitDeployment dep
```

## How load errors map to mistakes

When `nagarectl` loads a config, each failure becomes a precise `LoadError`
(from `Nagare.Dsl.Load`), printed as one line:

| `LoadError` | Cause | Message |
| --- | --- | --- |
| `FileNotFound` | config path doesn't exist | `nagare: config file not found: <path>` |
| `CompileError` | config won't compile / crashed | `nagare: compile error in <path>:` + GHC diagnostic |
| `MissingBinding` | ran but printed nothing (no `emitDeployment`) | `nagare: <path> compiled but did not produce a 'deployment' value` |
| `MarshalError` | a value failed a smart constructor | `nagare: field '<field>' failed validation: <message>` |

## Related docs

- [Deploying apps](deploying-apps.md) — the workflow and `nagarectl` commands.
- [App lifecycle](app-lifecycle.md) — day-2 `app`/`deployments` commands using the
  health-check, limits, and multiple-domain fields above.
- [Build modes](build-modes.md) — prebuilt, Dockerfile, and Nixpacks builds.
- [Secrets](secrets.md) — managing the Kubernetes Secrets that `EnvSecretRef`
  points at.
- [Reference](reference.md) — platform identifiers, registry path, ports.
- [MasterPlan](../masterplans/2-type-safe-haskell-deployment-dsl-for-nagarectl.md)
  — the design rationale and the substrate decision. The source under
  `cli/nagare-dsl/` is the authoritative contract if anything here drifts.
