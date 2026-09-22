module Nagare.Resource.Policy
  ( Sensitivity (..)
  , SecretRef
  , mkSecretRef
  , secretRefParts
  , RawCredential
  , rawCredential
  , RecoveryIntent (..)
  , DataPolicy (..)
  , LifecyclePolicy (..)
  , RetirementIntent (..)
  , DelegatedOperation (..)
  , Delegation (..)
  , RecoveryClass (..)
  )
where

import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty)
import Nagare.Dsl.Prelude
import Nagare.Resource.Types

data Sensitivity = Public | Private | Secret deriving stock (Eq, Ord, Show, Generic)

data SecretRef = SecretRef Name Name deriving stock (Eq, Ord, Show)

mkSecretRef :: Name -> Name -> SecretRef
mkSecretRef = SecretRef

secretRefParts :: SecretRef -> (Name, Name)
secretRefParts (SecretRef key version) = (key, version)

-- | Deliberately no Show, Generic or JSON instance. Never enters a declaration.
newtype RawCredential = RawCredential ByteString

rawCredential :: ByteString -> RawCredential
rawCredential = RawCredential

data RecoveryIntent = RecoveryIntent !Name !(NonEmpty SecretRef)
  deriving stock (Eq, Ord, Show, Generic)

data DataPolicy = Stateless | Durable !RecoveryIntent deriving stock (Eq, Ord, Show, Generic)

data LifecyclePolicy = Retain | DeleteWhenUnreferenced | Protect deriving stock (Eq, Ord, Show, Generic)

data RetirementIntent = RetainResources | CollectWithRecovery !RecoveryIntent deriving stock (Eq, Ord, Show, Generic)

-- | No constructor can grant deletion of the delegating parent.
data DelegatedOperation = RefreshCredential | ReconcileChildren deriving stock (Eq, Ord, Show, Generic)

data Delegation = Delegation
  {controller :: !ResourceId, fields :: !(NonEmpty Name), operations :: !(NonEmpty DelegatedOperation)}
  deriving stock (Eq, Ord, Show, Generic)

data RecoveryClass = Idempotent | VerifyBeforeRetry | OperatorRecovery deriving stock (Eq, Ord, Show, Generic)
