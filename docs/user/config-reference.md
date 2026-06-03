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
| `Nagare.Dsl.Presets` | Reusable building blocks: `webService`, overlays, helpers. |
| `Nagare.Dsl.Config` | `emitDeployment` — the last line of your config's `main`. |

---

## The `Deployment` record

```haskell
data Deployment = Deployment
  { name      :: ServiceName        -- required
  , namespace :: Namespace          -- required (use defaultNamespace for "personal")
  , image     :: ImageRef           -- required, no tag (the tag is added at deploy time)
  , domain    :: Maybe Domain       -- optional public hostname (DomainMapping)
  , port      :: Port               -- container port (defaultPort = 8080)
  , env       :: Map EnvName EnvVar -- environment variables (Map.empty for none)
  , resources :: Maybe Resources    -- CPU/memory requests (Nothing = omit)
  , scale     :: Maybe Scale        -- autoscaling bounds (Nothing = omit)
  }
```

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
deploy time (`nagarectl` computes a UTC timestamp tag, or you pass `--tag`). For
a real Nagare app the path is
`us-west1-docker.pkg.dev/tan-nb-exp/nagare/<app>`.

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

### `Resources`

```haskell
data Resources = Resources
  { cpu    :: Maybe Quantity
  , memory :: Maybe Quantity
  }
```

A plain record (no smart constructor) — but both fields are `Quantity`, so the
only way to populate them is through `mkQuantity`. Set the whole field to
`Nothing` on the `Deployment` to omit the `resources` block entirely.

### `Scale` — autoscaling bounds

```haskell
data Scale = Scale { minScale :: Int, maxScale :: Int }
mkScale :: Int -> Int -> Either Text Scale   -- mkScale min max
```

`mkScale` rejects negative values and requires `min <= max`. `minScale = 0`
means **scale to zero** when idle. Always build a `Scale` with `mkScale`;
constructing the record directly bypasses the check.

### `Domain` — optional public hostname

```haskell
mkDomain   :: Text -> Either Text Domain
domainText :: Domain -> Text
```

Non-empty, no spaces, and no URI scheme (`http://`/`https://`). When the
`Deployment`'s `domain` is `Just`, `nagarectl` also renders a `DomainMapping`.

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
| `webService name image` | A standard HTTP service: namespace `personal`, port `8080`, scale `0..3`, `stdResources` (250m / 128Mi), no env, no domain. |
| `development dep` | Overlay → scale `0..1` (still scale-to-zero, at most one replica). |
| `production dep` | Overlay → scale `1..5` (always-warm) and larger resources (500m / 256Mi). |
| `secretEnv var secret dep` | Adds a `EnvSecretRef` env var, preserving existing entries. |
| `stdResources` | The 250m / 128Mi resource block. |
| `teamDefaults dep` | Pins namespace `personal` and clears any custom domain. (Pure — returns `Deployment`, not `Either`.) |

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
- [Secrets](secrets.md) — managing the Kubernetes Secrets that `EnvSecretRef`
  points at.
- [Reference](reference.md) — platform identifiers, registry path, ports.
- [MasterPlan](../masterplans/2-type-safe-haskell-deployment-dsl-for-nagarectl.md)
  — the design rationale and the substrate decision. The source under
  `cli/nagare-dsl/` is the authoritative contract if anything here drifts.
