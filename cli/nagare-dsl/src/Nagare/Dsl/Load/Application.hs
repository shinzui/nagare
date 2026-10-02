-- | Application responsibilities; internal implementation behind Nagare.Dsl.Load.
module Nagare.Dsl.Load.Application
  ( decodeApplication
  )
where

import Data.Aeson
  ( FromJSON (..)
  , eitherDecodeStrict
  , withObject
  , (.!=)
  , (.:)
  , (.:?)
  )
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Nagare.Dsl.Application (Application (..), mkApplication)
import Nagare.Dsl.Load.Broker
  ( JsonBrokerBinding (..)
  , toBrokerBinding
  )
import Nagare.Dsl.Load.Database (JsonDatabase (..), toDatabase)
import Nagare.Dsl.Load.Deployment
  ( JsonDeployment (..)
  , toDeployment
  )
import Nagare.Dsl.Load.Error (LoadError (..))
import Nagare.Dsl.Load.Fields
  ( JsonAccessPolicy (..)
  , JsonEnvEntry (..)
  , JsonKindEnvelope (..)
  , toAccessPolicy
  , toEnvEntry
  )
import Nagare.Dsl.Load.Task (JsonTask (..), toTask)
import Nagare.Dsl.Load.Worker (JsonWorker (..), toWorker)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (mkImageRef, mkNamespace, mkServiceName)
import Nagare.Resource.Types (mkLogicalKey)

-- ---------------------------------------------------------------------------
-- JSON intermediate for the multi-workload Application aggregate (MasterPlan 14,
-- EP-1; mirrors Nagare.Dsl.Config's applicationJSON)

-- | The intermediate decode shape for an 'Application' (mirrors
-- 'Nagare.Dsl.Config'\'s @applicationJSON@). Each embedded workload reuses the
-- existing per-kind intermediate ('JsonDeployment' / 'JsonWorker' /
-- 'JsonDatabase' / 'JsonTask'), so the embedded objects decode exactly as they
-- do standalone. Optional fields default to empty so a partial object is a
-- precise 'MarshalError', not an aeson parse error.
data JsonApplication = JsonApplication
  { name :: !Text
  , logicalKey :: !(Maybe Text)
  , namespace :: !Text
  , image :: !Text
  , env :: ![JsonEnvEntry]
  , databases :: ![JsonDatabase]
  , brokers :: ![JsonBrokerBinding]
  , access :: !(Maybe JsonAccessPolicy)
  , service :: !(Maybe JsonDeployment)
  , workers :: ![JsonWorker]
  , tasks :: ![JsonTask]
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON JsonApplication where
  parseJSON = withObject "Application" $ \o ->
    JsonApplication
      <$> o .: "name"
      <*> o .:? "logicalKey"
      <*> o .: "namespace"
      <*> o .: "image"
      <*> o .:? "env" .!= []
      <*> o .:? "databases" .!= []
      <*> o .:? "brokers" .!= []
      <*> o .:? "access"
      <*> o .:? "service"
      <*> o .:? "workers" .!= []
      <*> o .:? "tasks" .!= []

-- | Re-validate a decoded application: re-run every leaf smart constructor for
-- the shared bindings, marshal each embedded workload with the EXISTING
-- 'toDeployment' / 'toWorker' / 'toDatabase' / 'toTask' (which re-run all their
-- own invariants), then enforce the cross-workload invariants by calling
-- 'mkApplication' on the assembled record — so the validation lives in one place
-- (defence in depth: a hand-written or tampered JSON that violates an invariant
-- is rejected as a precise @MarshalError "application"@).
toApplication :: JsonApplication -> Either LoadError Application
toApplication j = do
  name' <- first (MarshalError "name") $ mkServiceName (j ^. #name)
  logicalKey' <- traverse (first (MarshalError "logicalKey") . mkLogicalKey) (j ^. #logicalKey)
  ns' <- first (MarshalError "namespace") $ mkNamespace (j ^. #namespace)
  img' <- first (MarshalError "image") $ mkImageRef (j ^. #image)
  env' <- mapM toEnvEntry (j ^. #env)
  dbs' <- traverse toDatabase (j ^. #databases)
  brokerRefs' <- traverse (toBrokerBinding "brokers") (j ^. #brokers)
  access' <- traverse toAccessPolicy (j ^. #access)
  svc' <- traverse toDeployment (j ^. #service)
  wks' <- traverse toWorker (j ^. #workers)
  tks' <- traverse toTask (j ^. #tasks)
  let assembled =
        Application
          { name = name'
          , logicalKey = logicalKey'
          , namespace = ns'
          , image = img'
          , env = Map.fromList env'
          , databases = dbs'
          , brokers = brokerRefs'
          , access = access'
          , service = svc'
          , workers = wks'
          , tasks = tks'
          }
  first (MarshalError "application") (mkApplication assembled)

-- | Decode the JSON an application config emits (via
-- 'Nagare.Dsl.Config.emitApplication') into a validated 'Application'. The
-- top-level @kind@ is checked first: a missing kind (a bare 'Deployment') or a
-- non-@Application@ kind is 'UnexpectedKind'.
decodeApplication :: ByteString -> Either LoadError Application
decodeApplication bs =
  case eitherDecodeStrict bs of
    Left perr ->
      Left (MarshalError "json" ("could not decode config output: " <> Text.pack perr))
    Right (JsonKindEnvelope envelopeKind) -> case envelopeKind of
      Just "Application" -> case eitherDecodeStrict bs of
        Left perr ->
          Left (MarshalError "json" ("could not decode application: " <> Text.pack perr))
        Right ja -> toApplication ja
      Just other -> Left (UnexpectedKind "Application" other)
      Nothing -> Left (UnexpectedKind "Application" "<none>")
