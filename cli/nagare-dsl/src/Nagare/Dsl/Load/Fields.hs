-- | Fields responsibilities; internal implementation behind Nagare.Dsl.Load.
module Nagare.Dsl.Load.Fields
  ( JsonAccessPolicy (..)
  , JsonBuildSpec (..)
  , JsonDomainEntry (..)
  , JsonEnvEntry (..)
  , JsonHealthCheck (..)
  , JsonKindEnvelope (..)
  , JsonVolume (..)
  , checkTaskApp
  , firstDuplicate
  , toAccessPolicy
  , toBuildSpec
  , toDomainSpecs
  , toEnvEntry
  , toHealthCheck
  , toVolumes
  )
where

import Data.Aeson
  ( FromJSON (parseJSON)
  , withObject
  , (.!=)
  , (.:)
  , (.:?)
  )
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Nagare.Dsl.Access
  ( AccessPolicy (..)
  , AccessRole (AuthPortal, ProtectedSite)
  , mkAccessPermission
  , mkAudience
  )
import Nagare.Dsl.Build (BuildSpec (..), mkTag)
import Nagare.Dsl.Load.Error (LoadError (..))
import Nagare.Dsl.Prelude
import Nagare.Dsl.Static.Types (mkFilePathText)
import Nagare.Dsl.Task (Task)
import Nagare.Dsl.Types
  ( AccessMode (ReadWriteOnce)
  , DomainSpec
  , EnvName
  , EnvScope (..)
  , EnvVar (EnvLiteral, EnvSecretRef)
  , HealthCheck (..)
  , HealthScheme (HTTP, HTTPS)
  , RetentionPolicy (Delete, Retain)
  , ScopedEnvVar
  , Volume (..)
  , mkDomains
  , mkEnvName
  , mkHealthCheck
  , mkMountPath
  , mkPort
  , mkQuantity
  , mkSecretName
  , mkVolumeName
  , mountPathText
  , scopedEnv
  , serviceNameText
  , volumeNameText
  , withTlsSecret
  )
import Nagare.Resource.Types (mkLogicalKey)

-- ---------------------------------------------------------------------------
-- JSON intermediate (mirrors Nagare.Dsl.Config's emitted shape)

data JsonEnvEntry = JsonEnvEntry
  { varName :: !Text
  , kind :: !Text
  , value :: !(Maybe Text)
  , secretName :: !(Maybe Text)
  , scopes :: !(Maybe [Text])
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonEnvEntry where
  parseJSON = withObject "EnvEntry" $ \o ->
    JsonEnvEntry
      <$> o .: "varName"
      <*> o .: "kind"
      <*> o .:? "value"
      <*> o .:? "secretName"
      <*> o .:? "scopes"

-- | One entry of the @volumes@ array (mirrors 'Nagare.Dsl.Config'). Every
-- accessor is optional except the three required fields so a partial object is
-- reported as a precise 'MarshalError' rather than an aeson parse error; the
-- defaults mirror 'Nagare.Dsl.Presets.attachVolume' (RWO, not read-only,
-- Retain).
data JsonVolume = JsonVolume
  { name :: !Text
  , logicalKey :: !(Maybe Text)
  , size :: !Text
  , mountPath :: !Text
  , accessMode :: !(Maybe Text)
  , readOnly :: !Bool
  , retention :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonVolume where
  parseJSON = withObject "Volume" $ \o ->
    JsonVolume
      <$> o .: "name"
      <*> o .:? "logicalKey"
      <*> o .: "size"
      <*> o .: "mountPath"
      <*> o .:? "accessMode"
      <*> o .:? "readOnly" .!= False
      <*> o .:? "retention"

-- | The @build@ sub-object: a @"kind"@ discriminator plus the per-kind fields.
-- A 'PrebuiltImage' carries @tag@; a @DockerfileBuild@ carries
-- @dockerfile@/@context@/@buildArgs@; a @NixpacksBuild@ carries
-- @context@/@buildArgs@. All field accessors are optional so a precise
-- 'MarshalError' (rather than an aeson parse error) is produced when a required
-- field for a given kind is missing.
data JsonBuildSpec = JsonBuildSpec
  { kind :: !Text
  , tag :: !(Maybe Text)
  , dockerfile :: !(Maybe Text)
  , context :: !(Maybe Text)
  , buildArgs :: !(Map.Map Text Text)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonBuildSpec where
  parseJSON = withObject "BuildSpec" $ \o ->
    JsonBuildSpec
      <$> o .: "kind"
      <*> o .:? "tag"
      <*> o .:? "dockerfile"
      <*> o .:? "context"
      <*> o .:? "buildArgs" .!= mempty

-- | One entry of the @domains@ array: a hostname and its canonical marker.
-- @canonical@ defaults to 'False' when absent (an old single-domain config that
-- has been migrated, or hand-written JSON).
data JsonDomainTls = JsonDomainTls
  { mode :: !Text
  , secretName :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonDomainTls where
  parseJSON = withObject "DomainTls" $ \o ->
    JsonDomainTls
      <$> o .: "mode"
      <*> o .:? "secretName"

data JsonDomainSpec = JsonDomainSpec
  { domain :: !Text
  , canonical :: !Bool
  , tls :: !(Maybe JsonDomainTls)
  , logicalKey :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonDomainSpec where
  parseJSON = withObject "DomainSpec" $ \o ->
    JsonDomainSpec
      <$> o .: "domain"
      <*> o .:? "canonical" .!= False
      <*> o .:? "tls"
      <*> o .:? "logicalKey"

data JsonDomainEntry
  = JsonDomainObject !JsonDomainSpec
  | JsonDomainString !Text
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonDomainEntry where
  parseJSON value =
    (JsonDomainObject <$> parseJSON value)
      <|> (JsonDomainString <$> parseJSON value)

-- | Decode either the shared object representation or a complete legacy
-- string array. Legacy arrays preserve their historical first-entry canonical
-- behavior; mixed arrays are rejected so their canonical semantics cannot be
-- ambiguous.
toDomainSpecs :: Text -> [JsonDomainEntry] -> Either LoadError [DomainSpec]
toDomainSpecs _ [] = Right []
toDomainSpecs field entries
  | Just hosts <- traverse legacyHost entries =
      first (MarshalError field) $ mkDomains (zipWith (\i host -> (host, i == (0 :: Int))) [0 ..] hosts)
  | Just specs <- traverse objectSpec entries = do
      domains' <-
        first (MarshalError field) $
          mkDomains [(host, isCanonical) | JsonDomainSpec host isCanonical _ _ <- specs]
      traverse applyTls (zip specs domains')
  | otherwise = Left (MarshalError field "domain entries must be either all strings or all objects")
  where
    legacyHost (JsonDomainString host) = Just host
    legacyHost _ = Nothing
    objectSpec (JsonDomainObject spec) = Just spec
    objectSpec _ = Nothing

    applyTls (raw, spec) = do
      key <- traverse (first (MarshalError field) . mkLogicalKey) (raw ^. #logicalKey)
      let keyed = spec & #logicalKey .~ key
      case raw ^. #tls of
        Nothing -> Right keyed
        Just (JsonDomainTls "automatic" Nothing) -> Right keyed
        Just (JsonDomainTls "automatic" (Just _)) ->
          Left (MarshalError field "automatic TLS must not name a supplied secret")
        Just (JsonDomainTls "supplied-secret" Nothing) ->
          Left (MarshalError field "supplied-secret TLS requires secretName")
        Just (JsonDomainTls "supplied-secret" (Just rawSecret)) -> do
          secret <- first (MarshalError field) (mkSecretName rawSecret)
          Right (withTlsSecret secret keyed)
        Just (JsonDomainTls unknownMode _) ->
          Left (MarshalError field ("unknown domain TLS mode: " <> unknownMode))

-- | The @healthCheck@ sub-object (see 'Nagare.Dsl.Config'). Every field is
-- optional so a partial object is reported as a precise 'MarshalError' by
-- 'mkHealthCheck' rather than an aeson parse error; the defaults mirror
-- 'httpHealthCheck'.
data JsonHealthCheck = JsonHealthCheck
  { path :: !Text
  , checkPort :: !(Maybe Int)
  , scheme :: !Text
  , expectedStatus :: !Int
  , initialDelay :: !Int
  , period :: !Int
  , timeout :: !Int
  , failureThreshold :: !Int
  , asLiveness :: !Bool
  , asStartup :: !Bool
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonHealthCheck where
  parseJSON = withObject "HealthCheck" $ \o ->
    JsonHealthCheck
      <$> o .: "path"
      <*> o .:? "checkPort"
      <*> o .:? "scheme" .!= "HTTP"
      <*> o .:? "expectedStatus" .!= 200
      <*> o .:? "initialDelay" .!= 0
      <*> o .:? "period" .!= 10
      <*> o .:? "timeout" .!= 1
      <*> o .:? "failureThreshold" .!= 3
      <*> o .:? "asLiveness" .!= False
      <*> o .:? "asStartup" .!= False

data JsonAccessPolicy = JsonAccessPolicy
  { audience :: !(Maybe Text)
  , permission :: !Text
  , role :: !Text
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonAccessPolicy where
  parseJSON = withObject "AccessPolicy" $ \o ->
    JsonAccessPolicy
      <$> o .:? "audience"
      <*> o .:? "permission" .!= "access"
      <*> o .:? "role" .!= "protected"

toAccessPolicy :: JsonAccessPolicy -> Either LoadError AccessPolicy
toAccessPolicy j = do
  audience' <- traverse (first (MarshalError "access.audience") . mkAudience) (j ^. #audience)
  permission' <- first (MarshalError "access.permission") $ mkAccessPermission (j ^. #permission)
  role' <- case j ^. #role of
    "protected" -> Right ProtectedSite
    "portal" -> Right AuthPortal
    other -> Left (MarshalError "access.role" ("unknown access role: " <> other))
  Right AccessPolicy {audience = audience', permission = permission', role = role'}

-- | Re-validate a decoded @build@ sub-object back into a 'BuildSpec', dispatching
-- on its @kind@ and re-running the smart constructors. A missing per-kind field
-- or an unknown kind is reported as a precise 'MarshalError' (mirroring
-- 'toStaticBuild').
toBuildSpec :: JsonBuildSpec -> Either LoadError BuildSpec
toBuildSpec jb = case jb ^. #kind of
  "PrebuiltImage" -> do
    tag <-
      maybe (Left (MarshalError "build" "PrebuiltImage entry missing 'tag' field")) Right $
        jb ^. #tag
    fmap PrebuiltImage . first (MarshalError "build.tag") $ mkTag tag
  "DockerfileBuild" -> do
    df <-
      maybe (Left (MarshalError "build" "DockerfileBuild entry missing 'dockerfile' field")) Right $
        jb ^. #dockerfile
    ctx <-
      maybe (Left (MarshalError "build" "DockerfileBuild entry missing 'context' field")) Right $
        jb ^. #context
    df' <- first (MarshalError "build.dockerfile") $ mkFilePathText df
    ctx' <- first (MarshalError "build.context") $ mkFilePathText ctx
    Right (DockerfileBuild {dockerfile = df', context = ctx', buildArgs = jb ^. #buildArgs})
  "NixpacksBuild" -> do
    ctx <-
      maybe (Left (MarshalError "build" "NixpacksBuild entry missing 'context' field")) Right $
        jb ^. #context
    ctx' <- first (MarshalError "build.context") $ mkFilePathText ctx
    Right (NixpacksBuild {context = ctx', buildArgs = jb ^. #buildArgs})
  other -> Left (MarshalError "build.kind" ("unknown build kind: " <> other))

-- | Decode a single scope token, rejecting any unknown value with a precise
-- 'MarshalError'. The tokens are the capitalized 'Show' 'EnvScope' names.
parseScope :: Text -> Text -> Either LoadError EnvScope
parseScope var t = case t of
  "Runtime" -> Right Runtime
  "Build" -> Right Build
  "Preview" -> Right Preview
  other -> Left (MarshalError ("env." <> var <> ".scopes") ("unknown env scope: " <> other))

toEnvEntry :: JsonEnvEntry -> Either LoadError (EnvName, ScopedEnvVar)
toEnvEntry e = do
  n <- first (MarshalError "env.varName") $ mkEnvName (e ^. #varName)
  v <- case e ^. #kind of
    "Literal" -> case e ^. #value of
      Nothing -> Left (MarshalError ("env." <> e ^. #varName) "Literal entry missing 'value' field")
      Just lit -> Right (EnvLiteral lit)
    "SecretRef" -> case e ^. #secretName of
      Nothing -> Left (MarshalError ("env." <> e ^. #varName) "SecretRef entry missing 'secretName' field")
      Just sec ->
        fmap EnvSecretRef
          . first (MarshalError ("env." <> e ^. #varName <> ".secretRef"))
          $ mkSecretName sec
    other -> Left (MarshalError ("env." <> e ^. #varName <> ".kind") ("unknown env kind: " <> other))
  scopeList <- traverse (parseScope (e ^. #varName)) (fromMaybe [] (e ^. #scopes))
  let scopeSet = Set.fromList scopeList
      finalScopes = if Set.null scopeSet then Set.singleton Runtime else scopeSet
  sev <- first (MarshalError ("env." <> e ^. #varName <> ".scopes")) (scopedEnv finalScopes v)
  Right (n, sev)

-- | Re-validate a decoded @healthCheck@ sub-object back into a 'HealthCheck'.
-- The scheme string and probe port go through their constructors; the assembled
-- record is then re-checked by 'mkHealthCheck'. Any failure is a precise
-- 'MarshalError "healthCheck"'.
toHealthCheck :: Maybe JsonHealthCheck -> Either LoadError (Maybe HealthCheck)
toHealthCheck Nothing = Right Nothing
toHealthCheck (Just jhc) = do
  scheme' <- case jhc ^. #scheme of
    "HTTP" -> Right HTTP
    "HTTPS" -> Right HTTPS
    other -> Left (MarshalError "healthCheck.scheme" ("unknown scheme: " <> other))
  checkPort' <- traverse (first (MarshalError "healthCheck.checkPort") . mkPort) (jhc ^. #checkPort)
  fmap Just . first (MarshalError "healthCheck") $
    mkHealthCheck
      HealthCheck
        { path = jhc ^. #path
        , checkPort = checkPort'
        , scheme = scheme'
        , expectedStatus = jhc ^. #expectedStatus
        , initialDelay = jhc ^. #initialDelay
        , period = jhc ^. #period
        , timeout = jhc ^. #timeout
        , failureThreshold = jhc ^. #failureThreshold
        , asLiveness = jhc ^. #asLiveness
        , asStartup = jhc ^. #asStartup
        }

-- | The first element that appears more than once in the list, in order, or
-- 'Nothing' when all elements are unique. Used to reject duplicate co-located
-- task names (MasterPlan 10 / EP-52).
firstDuplicate :: (Ord a) => [a] -> Maybe a
firstDuplicate = go Set.empty
  where
    go _ [] = Nothing
    go seen (x : xs)
      | x `Set.member` seen = Just x
      | otherwise = go (Set.insert x seen) xs

-- | Deploy-level invariant (MasterPlan 10 / EP-52): a co-located task that names
-- an app via @app@ must name the enclosing app, not some other app.
checkTaskApp :: Text -> Task -> Either LoadError ()
checkTaskApp thisApp tk =
  case tk ^. #app of
    Just a
      | serviceNameText a /= thisApp ->
          Left
            ( MarshalError
                "tasks"
                ( "task '"
                    <> serviceNameText (tk ^. #name)
                    <> "' references app '"
                    <> serviceNameText a
                    <> "' but is co-located under app '"
                    <> thisApp
                    <> "'"
                )
            )
    _ -> Right ()

-- | Re-validate one decoded @volumes@ entry back into a 'Volume', re-running the
-- leaf smart constructors and decoding the access-mode / retention enums. Any
-- failure is a precise 'MarshalError' keyed by the sub-field.
toVolume :: JsonVolume -> Either LoadError Volume
toVolume jv = do
  vn <- first (MarshalError "volumes.name") $ mkVolumeName (jv ^. #name)
  logicalKey' <- traverse (first (MarshalError "volumes.logicalKey") . mkLogicalKey) (jv ^. #logicalKey)
  sz <- first (MarshalError "volumes.size") $ mkQuantity (jv ^. #size)
  mp <- first (MarshalError "volumes.mountPath") $ mkMountPath (jv ^. #mountPath)
  am <- case fromMaybe "ReadWriteOnce" (jv ^. #accessMode) of
    "ReadWriteOnce" -> Right ReadWriteOnce
    other -> Left (MarshalError "volumes.accessMode" ("unknown access mode: " <> other))
  rp <- case fromMaybe "Retain" (jv ^. #retention) of
    "Retain" -> Right Retain
    "Delete" -> Right Delete
    other -> Left (MarshalError "volumes.retention" ("unknown retention policy: " <> other))
  Right
    Volume
      { name = vn
      , logicalKey = logicalKey'
      , size = sz
      , mountPath = mp
      , accessMode = am
      , readOnly = jv ^. #readOnly
      , retention = rp
      }

-- | Re-validate the @volumes@ array and enforce the two cross-field uniqueness
-- invariants (no duplicate volume name, no duplicate mount path) that the pure
-- 'Volume' constructor cannot — producing a precise 'MarshalError "volumes"' on
-- a clash. This is the load-time check 'Nagare.Dsl.Presets.attachVolume' defers.
toVolumes :: [JsonVolume] -> Either LoadError [Volume]
toVolumes jvs = do
  vols <- traverse toVolume jvs
  let names = map (volumeNameText . (^. #name)) vols
      paths = map (mountPathText . (^. #mountPath)) vols
  ensureUnique "duplicate volume name" names
  ensureUnique "duplicate mount path" paths
  Right vols
  where
    ensureUnique msg xs =
      case firstDup xs of
        Nothing -> Right ()
        Just d -> Left (MarshalError "volumes" (msg <> ": " <> d))
    firstDup = go Set.empty
      where
        go _ [] = Nothing
        go seen (x : xs)
          | Set.member x seen = Just x
          | otherwise = go (Set.insert x seen) xs

-- ---------------------------------------------------------------------------
-- JSON intermediate for static sites (mirrors Nagare.Dsl.Config's emitted shape)

-- | A minimal envelope used to read the top-level @kind@ discriminator before
-- committing to a full decode.
newtype JsonKindEnvelope = JsonKindEnvelope {kind :: Maybe Text}
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonKindEnvelope where
  parseJSON = withObject "kinded" $ \o -> JsonKindEnvelope <$> o .:? "kind"
