{-# LANGUAGE GADTs #-}
{-# LANGUAGE RoleAnnotations #-}

module Nagare.Resource.Reference
  ( Capability (..)
  , Witness (..)
  , SomeWitness (..)
  , sameWitness
  , witnessCapability
  , OutputConstraint (..)
  , CapabilityRef
  , outputRef
  , refProducer
  , refKey
  , refWitness
  , refConstraints
  , refSensitivity
  , SomeRef (..)
  , SomeExport (..)
  , Dependency (..)
  , refSignature
  , exportSignature
  )
where

import Data.List (nub, sort)
import Data.Type.Equality ((:~:) (Refl))
import Nagare.Dsl.Prelude
import Nagare.Resource.Policy
import Nagare.Resource.Types

data Capability = DatabaseConnection | OciImage | StorageLocation | ReadinessCondition | TlsReady
  deriving stock (Eq, Ord, Show, Generic)

data Witness (c :: Capability) where
  DatabaseConnectionW :: Witness 'DatabaseConnection
  OciImageW :: Witness 'OciImage
  StorageLocationW :: Witness 'StorageLocation
  ReadinessConditionW :: Witness 'ReadinessCondition
  TlsReadyW :: Witness 'TlsReady

data SomeWitness where SomeWitness :: Witness c -> SomeWitness

sameWitness :: Witness a -> Witness b -> Maybe (a :~: b)
sameWitness DatabaseConnectionW DatabaseConnectionW = Just Refl
sameWitness OciImageW OciImageW = Just Refl
sameWitness StorageLocationW StorageLocationW = Just Refl
sameWitness ReadinessConditionW ReadinessConditionW = Just Refl
sameWitness TlsReadyW TlsReadyW = Just Refl
sameWitness _ _ = Nothing

witnessCapability :: Witness c -> Capability
witnessCapability DatabaseConnectionW = DatabaseConnection
witnessCapability OciImageW = OciImage
witnessCapability StorageLocationW = StorageLocation
witnessCapability ReadinessConditionW = ReadinessCondition
witnessCapability TlsReadyW = TlsReady

data OutputConstraint = NonEmptyOutput | InNamespace !Name | InProject !Name
  deriving stock (Eq, Ord, Show, Generic)

type role CapabilityRef nominal

data CapabilityRef (c :: Capability) = CapabilityRef (Witness c) ResourceId Name [OutputConstraint] Sensitivity

outputRef :: Witness c -> ResourceId -> Name -> [OutputConstraint] -> Sensitivity -> CapabilityRef c
outputRef w r k constraints sensitivity = CapabilityRef w r k (nub (sort constraints)) sensitivity

refProducer :: CapabilityRef c -> ResourceId
refProducer (CapabilityRef _ r _ _ _) = r

refKey :: CapabilityRef c -> Name
refKey (CapabilityRef _ _ k _ _) = k

refWitness :: CapabilityRef c -> Witness c
refWitness (CapabilityRef w _ _ _ _) = w

refConstraints :: CapabilityRef c -> [OutputConstraint]
refConstraints (CapabilityRef _ _ _ c _) = c

refSensitivity :: CapabilityRef c -> Sensitivity
refSensitivity (CapabilityRef _ _ _ _ s) = s

data SomeRef where SomeRef :: CapabilityRef c -> SomeRef

data SomeExport where SomeExport :: CapabilityRef c -> SomeExport

refSignature :: SomeRef -> (ResourceId, Name, Capability, [OutputConstraint], Sensitivity)
refSignature (SomeRef r) = (refProducer r, refKey r, witnessCapability (refWitness r), refConstraints r, refSensitivity r)

exportSignature :: SomeExport -> (ResourceId, Name, Capability, [OutputConstraint], Sensitivity)
exportSignature (SomeExport r) = refSignature (SomeRef r)

instance Eq SomeRef where a == b = refSignature a == refSignature b

instance Ord SomeRef where compare a b = compare (refSignature a) (refSignature b)

instance Show SomeRef where show = show . refSignature

instance Eq SomeExport where a == b = exportSignature a == exportSignature b

instance Ord SomeExport where compare a b = compare (exportSignature a) (exportSignature b)

instance Show SomeExport where show = show . exportSignature

data Dependency = Consumes !SomeRef | ReadyAfter !SomeRef | OrderedAfter !ResourceId
  deriving stock (Eq, Ord, Show, Generic)
