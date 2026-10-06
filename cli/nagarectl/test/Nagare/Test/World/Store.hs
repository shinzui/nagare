-- | EP-173 M2: an inventory object store whose puts and gets an adversary can
-- refuse, land without acknowledgement, or fail once. It wraps any 'ObjectOps'
-- (normally the in-memory fake), generalizing the F38 spec's faulting store.
module Nagare.Test.World.Store
  ( faultingObjectOps
  )
where

import Control.Exception (throwIO)
import Data.Aeson (Value (..), eitherDecodeStrict')
import Data.Aeson.KeyMap qualified as KM
import Data.IORef
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Store.ObjectOps
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Test.World.Adversary

faultingObjectOps :: IORef Adversary -> ObjectOps -> ObjectOps
faultingObjectOps adversary base =
  base
    { putObject = \condition name bytes -> do
        fault <- nextFault adversary StorePutCall
        case fault of
          Just PutRefused -> pure (PutUnknown "injected: store write refused before landing")
          Just PutLandedUnacknowledged -> do
            _ <- putObject base condition name bytes
            pure (PutUnknown "injected: store write acknowledgement lost")
          Just CrashBeforeStorePut -> throwIO Interrupted
          Just CrashAfterStorePut -> putObject base condition name bytes >> throwIO Interrupted
          Just ClaimLost -> stealClaim condition name >> putObject base condition name bytes
          _ -> putObject base condition name bytes
    , getObject = \name -> do
        fault <- nextFault adversary StoreGetCall
        case fault of
          Just GetFailedOnce -> pure (GetUnknown "injected: store read failed")
          _ -> getObject base name
    }
  where
    -- Another client's claim lands at the generation this write expects, so
    -- the write itself then conflicts and the executor finds it has lost.
    stealClaim condition (ObjectName name) = case condition of
      IfGenerationMatches generation | "head.json" `T.isSuffixOf` name -> do
        current <- getObject base (ObjectName name)
        case current of
          ObjectFound found bytes
            | found == generation
            , Right (Object root) <- eitherDecodeStrict' bytes
            , Just (Object claim) <- KM.lookup "executorClaim" root
            , Right stolen <- canonicalValue (Object (KM.insert "executorClaim" (Object (KM.insert "clientIdentity" (String "model-intruder") claim)) root)) ->
                () <$ putObject base condition (ObjectName name) stolen
          _ -> pure ()
      _ -> pure ()
