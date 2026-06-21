-- | Serialization helpers for config-as-program files.
--
-- An app's @Config.hs@ imports this module and calls 'emitDeployment' as the
-- last action of @main@ to hand its already-validated 'Deployment' value to
-- @nagarectl@/the loader over stdout, encoded as JSON. The loader
-- ('Nagare.Dsl.Load.loadDeployment') decodes that JSON and re-runs the smart
-- constructors as defence in depth.
module Nagare.Dsl.Config
  ( emitDeployment
  , encodeDeployment
  , emitBroker
  , encodeBroker
  , emitDatabase
  , encodeDatabase
  , emitStaticSite
  , encodeStaticSite
  , emitServerSite
  , encodeServerSite
  , emitTask
  , encodeTask
  , emitWorker
  , encodeWorker
  , emitApplication
  , encodeApplication
  )
where

import Data.Aeson (Value, encode, object, toJSON, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.List (sortOn)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Nagare.Dsl.Application (Application)
import Nagare.Dsl.Broker
import Nagare.Dsl.Build
import Nagare.Dsl.Cdn.Types
import Nagare.Dsl.Database
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Server.Types
import Nagare.Dsl.Static.Types
import Nagare.Dsl.Task
import Nagare.Dsl.Types
import Nagare.Dsl.Worker (Worker, WorkerProbe (..), commandArgvList, probeTiming, replicasInt)
import "generic-lens" Data.Generics.Labels ()

-- | Serialize a 'Deployment' to JSON and write it to stdout. Call this as the
-- last line of your @Config.hs@ @main@.
emitDeployment :: Deployment -> IO ()
emitDeployment dep = LBS.putStr (encodeDeployment dep)

-- | The exact JSON bytes 'emitDeployment' writes. Exposed so the emit→decode
-- round-trip can be exercised in-process (without capturing stdout or spawning
-- @runghc@).
encodeDeployment :: Deployment -> LBS.ByteString
encodeDeployment = encode . deploymentJSON

-- | Serialize a 'Broker' to JSON and write it to stdout. The top-level
-- @"kind": "Broker"@ discriminator lets loader and CLI code reject configs run
-- under the wrong command.
emitBroker :: Broker -> IO ()
emitBroker broker = LBS.putStr (encodeBroker broker)

-- | The exact JSON bytes 'emitBroker' writes.
encodeBroker :: Broker -> LBS.ByteString
encodeBroker = encode . brokerJSON

brokerJSON :: Broker -> Value
brokerJSON broker =
  object
    [ "kind" .= ("Broker" :: Text)
    , "name" .= brokerNameText (broker ^. #name)
    , "provider" .= brokerProviderToken (broker ^. #provider)
    , "version" .= brokerVersionText (broker ^. #version)
    , "namespace" .= namespaceText (broker ^. #namespace)
    , "storageSize" .= quantityText (broker ^. #storageSize)
    , "cpuRequest" .= fmap quantityText (res >>= (^. #cpu))
    , "memoryRequest" .= fmap quantityText (res >>= (^. #memory))
    , "cpuLimit" .= fmap quantityText (res >>= (^. #cpuLimit))
    , "memoryLimit" .= fmap quantityText (res >>= (^. #memoryLimit))
    , "redpandaSmp" .= (broker ^. #sizing . #smp)
    , "redpandaMemory" .= quantityText (broker ^. #sizing . #memory)
    , "topics" .= map topicJSON (broker ^. #topics)
    ]
  where
    res = broker ^. #sizing . #resources

topicJSON :: BrokerTopic -> Value
topicJSON topic =
  object
    [ "name" .= topicNameText (topic ^. #name)
    , "partitions" .= (topic ^. #partitions)
    , "replicationFactor" .= (topic ^. #replicationFactor)
    , "retentionMs" .= (topic ^. #retentionMs)
    ]

-- | Serialize a 'Database' to JSON and write it to stdout. Call this as the last
-- line of a database project's @Config.hs@ @main@. The top-level
-- @"kind": "Database"@ discriminator lets the loader dispatch and report a
-- precise 'Nagare.Dsl.Load.UnexpectedKind' if a Database config is run under
-- @nagarectl deploy@.
emitDatabase :: Database -> IO ()
emitDatabase db = LBS.putStr (encodeDatabase db)

-- | The exact JSON bytes 'emitDatabase' writes (exposed for the round-trip test).
encodeDatabase :: Database -> LBS.ByteString
encodeDatabase = encode . databaseJSON

-- | The JSON shape the loader reads back (see 'Nagare.Dsl.Load.decodeDatabase').
-- The four flat resource keys mirror exactly how 'deploymentJSON' serializes
-- 'Resources', so the loader reuses the same marshalling step.
databaseJSON :: Database -> Value
databaseJSON db =
  object
    [ "kind" .= ("Database" :: Text)
    , "name" .= databaseNameText (db ^. #dbName)
    , "engine" .= engineToken (db ^. #engine)
    , "version" .= engineVersionText (db ^. #version)
    , "namespace" .= namespaceText (db ^. #namespace)
    , "size" .= quantityText (db ^. #size)
    , "cpuRequest" .= fmap quantityText (res >>= (^. #cpu))
    , "memoryRequest" .= fmap quantityText (res >>= (^. #memory))
    , "cpuLimit" .= fmap quantityText (res >>= (^. #cpuLimit))
    , "memoryLimit" .= fmap quantityText (res >>= (^. #memoryLimit))
    , "retention" .= retentionToken (db ^. #retention)
    ]
  where
    res = db ^. #resources
    retentionToken Retain = "Retain" :: Text
    retentionToken Delete = "Delete"

-- | Serialize a 'Task' to JSON and write it to stdout. Call this as the last
-- line of a task project's @Config.hs@ @main@. The top-level @"kind": "Task"@
-- discriminator lets the loader dispatch and report a precise
-- 'Nagare.Dsl.Load.UnexpectedKind' if a Task config is run under the wrong
-- command.
emitTask :: Task -> IO ()
emitTask t = LBS.putStr (encodeTask t)

-- | The exact JSON bytes 'emitTask' writes (exposed for the round-trip test).
encodeTask :: Task -> LBS.ByteString
encodeTask = encode . taskJSON

-- | The JSON shape the loader reads back (see 'Nagare.Dsl.Load.decodeTask').
taskJSON :: Task -> Value
taskJSON t =
  object
    [ "kind" .= ("Task" :: Text)
    , "name" .= serviceNameText (taskName t)
    , "namespace" .= namespaceText (taskNamespace t)
    , "schedule" .= scheduleText (taskSchedule t)
    , "image" .= fmap imageRefText (taskImage t)
    , "app" .= fmap serviceNameText (taskApp t)
    , "command" .= taskCommand t
    , "args" .= taskArgs t
    , "env" .= map taskEnvJSON (Map.toAscList (taskEnv t))
    , "cpuRequest" .= fmap quantityText (res >>= (^. #cpu))
    , "memoryRequest" .= fmap quantityText (res >>= (^. #memory))
    , "cpuLimit" .= fmap quantityText (res >>= (^. #cpuLimit))
    , "memoryLimit" .= fmap quantityText (res >>= (^. #memoryLimit))
    , "timeoutSeconds" .= taskTimeoutSeconds t
    , "concurrencyPolicy" .= concurrencyPolicyToken (taskConcurrencyPolicy t)
    , "restartPolicy" .= restartPolicyToken (taskRestartPolicy t)
    , "backoffLimit" .= taskBackoffLimit t
    , "successfulJobsHistoryLimit" .= taskSuccessfulJobsHistoryLimit t
    , "failedJobsHistoryLimit" .= taskFailedJobsHistoryLimit t
    , "startingDeadlineSeconds" .= taskStartingDeadlineSeconds t
    ]
  where
    res = taskResources t
    taskEnvJSON (n, sev) = case sev ^. #value of
      EnvLiteral lit ->
        object
          [ "varName" .= envNameText n
          , "kind" .= ("Literal" :: Text)
          , "value" .= lit
          , "scopes" .= scopeTokensJSON sev
          ]
      EnvSecretRef sn ->
        object
          [ "varName" .= envNameText n
          , "kind" .= ("SecretRef" :: Text)
          , "secretName" .= secretNameText sn
          , "scopes" .= scopeTokensJSON sev
          ]

-- | The JSON shape of one 'Volume', shared by 'Deployment' and 'ServerSite'
-- emission. The loader reads it back in 'Nagare.Dsl.Load.toVolume'; @accessMode@
-- and @retention@ are the 'Show'-style enum tokens.
volumeJSON :: Volume -> Value
volumeJSON v =
  object
    [ "name" .= volumeNameText (v ^. #volName)
    , "size" .= quantityText (v ^. #size)
    , "mountPath" .= mountPathText (v ^. #mountPath)
    , "accessMode" .= accessModeToken (v ^. #accessMode)
    , "readOnly" .= (v ^. #readOnly)
    , "retention" .= retentionToken (v ^. #retention)
    ]
  where
    accessModeToken ReadWriteOnce = "ReadWriteOnce" :: Text
    retentionToken Retain = "Retain" :: Text
    retentionToken Delete = "Delete"

-- | The JSON shape of a 'BuildSpec', shared by 'deploymentJSON' and 'workerJSON'
-- so both emit one byte-identical @build@ contract the loader's 'toBuildSpec'
-- reads back. A @"kind"@ discriminator selects the per-kind fields.
buildSpecJSON :: BuildSpec -> Value
buildSpecJSON (PrebuiltImage t) =
  object
    [ "kind" .= ("PrebuiltImage" :: Text)
    , "tag" .= tagText t
    ]
buildSpecJSON (DockerfileBuild df ctx args) =
  object
    [ "kind" .= ("DockerfileBuild" :: Text)
    , "dockerfile" .= filePathText df
    , "context" .= filePathText ctx
    , "buildArgs" .= args
    ]
buildSpecJSON (NixpacksBuild ctx args) =
  object
    [ "kind" .= ("NixpacksBuild" :: Text)
    , "context" .= filePathText ctx
    , "buildArgs" .= args
    ]

-- | The JSON shape of one scoped env entry, shared by 'workerJSON' (and matching
-- byte-for-byte the inline encoders in 'deploymentJSON' / 'serverSiteJSON' /
-- 'taskJSON'). The loader reads it back in 'Nagare.Dsl.Load.toEnvEntry'.
scopedEnvJSON :: (EnvName, ScopedEnvVar) -> Value
scopedEnvJSON (n, sev) = case sev ^. #value of
  EnvLiteral lit ->
    object
      [ "varName" .= envNameText n
      , "kind" .= ("Literal" :: Text)
      , "value" .= lit
      , "scopes" .= scopeTokensJSON sev
      ]
  EnvSecretRef sn ->
    object
      [ "varName" .= envNameText n
      , "kind" .= ("SecretRef" :: Text)
      , "secretName" .= secretNameText sn
      , "scopes" .= scopeTokensJSON sev
      ]

-- | Serialize a 'Worker' to JSON and write it to stdout (EP-71). Call this as the
-- last line of a worker project's @Config.hs@ @main@. The top-level
-- @"kind": "Worker"@ discriminator lets the loader dispatch and report a precise
-- 'Nagare.Dsl.Load.UnexpectedKind' if a Worker config is run under the wrong
-- command.
emitWorker :: Worker -> IO ()
emitWorker w = LBS.putStr (encodeWorker w)

-- | The exact JSON bytes 'emitWorker' writes (exposed for the round-trip test).
encodeWorker :: Worker -> LBS.ByteString
encodeWorker = encode . workerJSON

-- | The JSON shape the loader reads back (see 'Nagare.Dsl.Load.decodeWorker').
-- The four flat resource keys mirror 'deploymentJSON'/'databaseJSON', and
-- @build@/@env@/@volumes@ reuse the shared encoders, so the loader reuses the
-- same marshalling steps. @command@ is a JSON array (or @null@ for the image
-- default); @replicas@ is an Int.
workerJSON :: Worker -> Value
workerJSON w =
  object
    [ "kind" .= ("Worker" :: Text)
    , "name" .= serviceNameText (w ^. #name)
    , "namespace" .= namespaceText (w ^. #namespace)
    , "image" .= imageRefText (w ^. #image)
    , "build" .= buildSpecJSON (w ^. #build)
    , "command" .= fmap commandArgvList (w ^. #command)
    , "replicas" .= replicasInt (w ^. #replicas)
    , "env" .= map scopedEnvJSON (Map.toAscList (w ^. #env))
    , "cpuRequest" .= fmap quantityText (res >>= (^. #cpu))
    , "memoryRequest" .= fmap quantityText (res >>= (^. #memory))
    , "cpuLimit" .= fmap quantityText (res >>= (^. #cpuLimit))
    , "memoryLimit" .= fmap quantityText (res >>= (^. #memoryLimit))
    , "volumes" .= map volumeJSON (w ^. #volumes)
    , "databases" .= map databaseNameText (w ^. #databases)
    , "liveness" .= fmap workerProbeJSON (w ^. #liveness)
    ]
  where
    res = w ^. #resources

-- | The JSON shape of a worker liveness probe (EP-74). A @"kind"@ discriminator
-- (@"Exec"|"Tcp"|"Http"@) selects the per-mechanism fields; the shared timing is
-- emitted flat alongside. The loader reads it back in
-- 'Nagare.Dsl.Load.toWorkerProbe'. A @Nothing@ probe is encoded as JSON @null@
-- (the @"liveness"@ key above), matching how @deploymentJSON@ emits an absent
-- @healthCheck@, so a no-probe worker stays byte-identical to today.
workerProbeJSON :: WorkerProbe -> Value
workerProbeJSON p = object (kindPairs <> timingPairs)
  where
    t = probeTiming p
    kindPairs = case p of
      ExecProbe argv _ -> ["kind" .= ("Exec" :: Text), "command" .= argv]
      TcpProbe port _ -> ["kind" .= ("Tcp" :: Text), "port" .= portInt port]
      HttpProbe path mport scheme _ ->
        [ "kind" .= ("Http" :: Text)
        , "path" .= path
        , "checkPort" .= fmap portInt mport
        , "scheme" .= schemeTok scheme
        ]
    timingPairs =
      [ "initialDelay" .= (t ^. #initialDelay)
      , "period" .= (t ^. #period)
      , "timeout" .= (t ^. #timeout)
      , "failureThreshold" .= (t ^. #failureThreshold)
      , "asStartup" .= (t ^. #asStartup)
      ]
    schemeTok HTTP = "HTTP" :: Text
    schemeTok HTTPS = "HTTPS"

-- | The nested @"cdn"@ object emitted inside a static site, server site, or
-- deployment (MasterPlan 11, EP-55). Provider tokens are the wire contract
-- EP-56/EP-57/EP-58 read: @"Cloudflare"@ and @"GcpCloudCdn"@. A per-path rule's
-- @edgeTtlSeconds: null@ encodes the "never cache this path" case.
cdnJSON :: Cdn -> Value
cdnJSON c =
  object
    [ "provider" .= providerToken (c ^. #provider)
    , "defaultTtlSeconds" .= (c ^. #defaultTtlSeconds)
    , "cacheStaticAssets" .= (c ^. #cacheStaticAssets)
    , "cacheRules" .= map ruleJSON (c ^. #cacheRules)
    ]
  where
    providerToken CloudflareCdn = "Cloudflare" :: Text
    providerToken GcpCloudCdn = "GcpCloudCdn"
    ruleJSON r =
      object
        [ "pathPrefix" .= (r ^. #pathPrefix)
        , "edgeTtlSeconds" .= (r ^. #edgeTtlSeconds)
        ]

-- | The scope set of a 'ScopedEnvVar' as a JSON-ready list of capitalized
-- tokens matching the 'Show' 'EnvScope' names (@"Runtime"@, @"Build"@,
-- @"Preview"@), sorted ascending for deterministic output. These capitalized
-- tokens are distinct from the lowercased resource-name tokens
-- ('Nagare.Dsl.Render.scopeToken').
scopeTokensJSON :: ScopedEnvVar -> [Text]
scopeTokensJSON sev = map (Text.pack . show) (Set.toAscList (sev ^. #scopes))

-- | The JSON shape the loader reads back (see 'Nagare.Dsl.Load').
deploymentJSON :: Deployment -> Value
deploymentJSON dep =
  object $
    [ "name" .= serviceNameText (dep ^. #name)
    , "namespace" .= namespaceText (dep ^. #namespace)
    , "image" .= imageRefText (dep ^. #image)
    , "build" .= buildSpecJSON (dep ^. #build)
    , "domains" .= map domainSpecJSON (dep ^. #domains)
    , "port" .= portInt (dep ^. #port)
    , "env" .= map envJSON (Map.toAscList (dep ^. #env))
    , "cpuRequest" .= fmap quantityText (resources >>= (^. #cpu))
    , "memoryRequest" .= fmap quantityText (resources >>= (^. #memory))
    , "cpuLimit" .= fmap quantityText (resources >>= (^. #cpuLimit))
    , "memoryLimit" .= fmap quantityText (resources >>= (^. #memoryLimit))
    , "scaleMin" .= fmap (^. #minScale) scale
    , "scaleMax" .= fmap (^. #maxScale) scale
    , "healthCheck" .= fmap healthCheckJSON (dep ^. #healthCheck)
    , "volumes" .= map volumeJSON (dep ^. #volumes)
    , "databases" .= map databaseNameText (dep ^. #databases)
    , "tasks" .= map taskJSON (sortOn taskName (dep ^. #tasks))
    ]
      <> maybe [] (\c -> ["cdn" .= cdnJSON c]) (dep ^. #cdn)
  where
    resources = dep ^. #resources
    scale = dep ^. #scale

    domainSpecJSON ds =
      object
        [ "domain" .= domainText (ds ^. #domain)
        , "canonical" .= (ds ^. #canonical)
        ]

    healthCheckJSON hc =
      object
        [ "path" .= (hc ^. #path)
        , "checkPort" .= fmap portInt (hc ^. #checkPort)
        , "scheme" .= schemeText (hc ^. #scheme)
        , "expectedStatus" .= (hc ^. #expectedStatus)
        , "initialDelay" .= (hc ^. #initialDelay)
        , "period" .= (hc ^. #period)
        , "timeout" .= (hc ^. #timeout)
        , "failureThreshold" .= (hc ^. #failureThreshold)
        , "asLiveness" .= (hc ^. #asLiveness)
        , "asStartup" .= (hc ^. #asStartup)
        ]

    schemeText :: HealthScheme -> Text
    schemeText HTTP = "HTTP"
    schemeText HTTPS = "HTTPS"

    envJSON (n, sev) = case sev ^. #value of
      EnvLiteral lit ->
        object
          [ "varName" .= envNameText n
          , "kind" .= ("Literal" :: Text)
          , "value" .= lit
          , "scopes" .= scopeTokensJSON sev
          ]
      EnvSecretRef sn ->
        object
          [ "varName" .= envNameText n
          , "kind" .= ("SecretRef" :: Text)
          , "secretName" .= secretNameText sn
          , "scopes" .= scopeTokensJSON sev
          ]

-- | Serialize a 'StaticSite' to JSON and write it to stdout. Call this as the
-- last line of a static project's @Config.hs@ @main@. The top-level
-- @"kind": "StaticSite"@ discriminator lets the loader report a precise error if
-- a config emits the wrong shape under @nagarectl site deploy@.
emitStaticSite :: StaticSite -> IO ()
emitStaticSite site = LBS.putStr (encodeStaticSite site)

-- | The exact JSON bytes 'emitStaticSite' writes (exposed for the round-trip
-- test, mirroring 'encodeDeployment').
encodeStaticSite :: StaticSite -> LBS.ByteString
encodeStaticSite = encode . staticSiteJSON

-- | The JSON shape the loader reads back (see 'Nagare.Dsl.Load.decodeStaticSite').
staticSiteJSON :: StaticSite -> Value
staticSiteJSON site =
  object $
    [ "kind" .= ("StaticSite" :: Text)
    , "name" .= siteNameText (site ^. #name)
    , "namespace" .= namespaceText (site ^. #namespace)
    , "image" .= imageRefText (site ^. #image)
    , "build" .= buildJSON (site ^. #build)
    , "domains" .= map domainText (site ^. #domains)
    , "redirects" .= map redirectJSON (site ^. #redirects)
    , "headers" .= map headerJSON (site ^. #headers)
    , "cache" .= cacheJSON (site ^. #cache)
    , "notFound" .= fmap filePathText (site ^. #notFound)
    ]
      <> maybe [] (\c -> ["cdn" .= cdnJSON c]) (site ^. #cdn)
  where
    buildJSON (NoBuild dir) =
      object
        [ "kind" .= ("NoBuild" :: Text)
        , "directory" .= filePathText dir
        ]
    buildJSON (BuildCommand cmd outDir) =
      object
        [ "kind" .= ("BuildCommand" :: Text)
        , "command" .= cmd
        , "outputDirectory" .= filePathText outDir
        ]

    redirectJSON r =
      object
        [ "from" .= (r ^. #from)
        , "to" .= (r ^. #to)
        , "status" .= (r ^. #status)
        ]

    headerJSON h =
      object
        [ "path" .= (h ^. #path)
        , "name" .= (h ^. #name)
        , "value" .= (h ^. #value)
        ]

    cacheJSON cp =
      object
        [ "immutableAssets" .= immutableAssets cp
        , "defaultMaxAge" .= defaultMaxAge cp
        ]

-- | Serialize a 'ServerSite' to JSON and write it to stdout (EP-18). Call this
-- as the last line of a server project's @Config.hs@ @main@. The top-level
-- @"kind": "ServerSite"@ discriminator lets the loader dispatch and report a
-- precise error if the wrong shape is deployed.
emitServerSite :: ServerSite -> IO ()
emitServerSite site = LBS.putStr (encodeServerSite site)

-- | The exact JSON bytes 'emitServerSite' writes (exposed for the round-trip
-- test, mirroring 'encodeDeployment').
encodeServerSite :: ServerSite -> LBS.ByteString
encodeServerSite = encode . serverSiteJSON

serverSiteJSON :: ServerSite -> Value
serverSiteJSON site =
  object $
    [ "kind" .= ("ServerSite" :: Text)
    , "name" .= siteNameText (site ^. #name)
    , "namespace" .= namespaceText (site ^. #namespace)
    , "image" .= imageRefText (site ^. #image)
    , "build" .= buildJSON (site ^. #build)
    , "runtime" .= runtimeJSON (site ^. #runtime)
    , "port" .= portInt (site ^. #port)
    , "env" .= map envEntryJSON (Map.toAscList (site ^. #env))
    , "cpuRequest" .= fmap quantityText (resources >>= (^. #cpu))
    , "memoryRequest" .= fmap quantityText (resources >>= (^. #memory))
    , "scaleMin" .= fmap (^. #minScale) scale
    , "scaleMax" .= fmap (^. #maxScale) scale
    , "domains" .= map domainText (site ^. #domains)
    , "volumes" .= map volumeJSON (site ^. #volumes)
    ]
      <> maybe [] (\c -> ["cdn" .= cdnJSON c]) (site ^. #cdn)
  where
    resources = site ^. #resources
    scale = site ^. #scale

    buildJSON b =
      object
        [ "command" .= (b ^. #command)
        , "outputDirs" .= map filePathText (NE.toList (b ^. #outputDirs))
        ]
    runtimeJSON r =
      object
        [ "baseImage" .= runtimeImageText (r ^. #baseImage)
        , "startCommand" .= toJSON (NE.toList (r ^. #startCommand))
        ]

    envEntryJSON (n, sev) = case sev ^. #value of
      EnvLiteral lit ->
        object
          [ "varName" .= envNameText n
          , "kind" .= ("Literal" :: Text)
          , "value" .= lit
          , "scopes" .= scopeTokensJSON sev
          ]
      EnvSecretRef sn ->
        object
          [ "varName" .= envNameText n
          , "kind" .= ("SecretRef" :: Text)
          , "secretName" .= secretNameText sn
          , "scopes" .= scopeTokensJSON sev
          ]

-- | Serialize an 'Application' to JSON and write it to stdout (MasterPlan 14,
-- EP-1). Call this as the last line of a multi-workload app's @Config.hs@ @main@.
-- The top-level @"kind": "Application"@ discriminator lets the loader dispatch and
-- report a precise 'Nagare.Dsl.Load.UnexpectedKind' if an Application config is
-- run under the wrong command.
emitApplication :: Application -> IO ()
emitApplication app = LBS.putStr (encodeApplication app)

-- | The exact JSON bytes 'emitApplication' writes (exposed for the round-trip
-- test, mirroring 'encodeWorker').
encodeApplication :: Application -> LBS.ByteString
encodeApplication = encode . applicationJSON

-- | The JSON shape the loader reads back (see
-- 'Nagare.Dsl.Load.decodeApplication'). The shared @image@/@env@/@databases@ are
-- the single source of truth at the aggregate level; each embedded workload
-- serializes with its EXISTING per-kind encoder ('deploymentJSON' / 'workerJSON'
-- / 'databaseJSON' / 'taskJSON') verbatim, so it round-trips unchanged and any
-- future workload field flows through automatically. Every list is sorted by name
-- so the bytes are deterministic for golden comparison, exactly as
-- 'deploymentJSON' sorts its co-located tasks.
applicationJSON :: Application -> Value
applicationJSON app =
  object
    [ "kind" .= ("Application" :: Text)
    , "name" .= serviceNameText (app ^. #appName)
    , "namespace" .= namespaceText (app ^. #namespace)
    , "image" .= imageRefText (app ^. #image)
    , "env" .= map scopedEnvJSON (Map.toAscList (app ^. #env))
    , "databases"
        .= map databaseJSON (sortOn (\db -> databaseNameText (db ^. #dbName)) (app ^. #appDatabases))
    , "service" .= fmap deploymentJSON (app ^. #service)
    , "workers"
        .= map workerJSON (sortOn (\w -> serviceNameText (w ^. #name)) (app ^. #workers))
    , "tasks" .= map taskJSON (sortOn taskName (app ^. #tasks))
    ]
