-- | Explicit teardown policy for finite stateless cloud resources. Data,
-- credentials, published artifacts and provider/store authority remain protected.
module Nagare.Inventory.CloudCollection
  ( cloudCollectionTypes
  , cloudCollectionEligible
  , cloudCollectionPhysicalDigest
  , validateCloudCollectionProtection
  , cloudCollectionPolicyOnly
  , compileCloudCollectionPolicy
  , cloudCollectionProgramDigest
  , encodeCloudCollectionBundle
  )
where

import Control.Monad (forM_)
import Data.Aeson
import Data.Aeson.KeyMap qualified
import Data.Aeson.Types qualified
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Cloud
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (DeleteWhenUnreferenced, Protect))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

cloudCollectionTypes :: [Text]
cloudCollectionTypes =
  [ "gcp:compute/address:Address"
  , "gcp:compute/firewall:Firewall"
  , "gcp:compute/instance:Instance"
  , "gcp:compute/network:Network"
  , "gcp:compute/subnetwork:Subnetwork"
  , "gcp:dns/managedZone:ManagedZone"
  , "gcp:dns/recordSet:RecordSet"
  , "nagare:compute:NagareInstance"
  , "nagare:env:NagareNixCache"
  , "nagare:net:NagareNetwork"
  ]

cloudCollectionEligible :: ManagedResource -> Bool
cloudCollectionEligible resource =
  resource ^. #executor == PulumiExecutor
    && scopeKind (resource ^. #owner) == Platform
    && nameText (scopeName (resource ^. #owner)) == "cloud"
    && resource ^. #dataPolicy == Stateless
    && case registrationsFromDeclarations [Managed resource] of
      Right [registration] -> registrationPulumiType registration `elem` cloudCollectionTypes
      _ -> False

-- This exact metadata transition needs fresh native verification, not Pulumi up.
cloudCollectionPolicyOnly :: ManagedResource -> ManagedResource -> Bool
cloudCollectionPolicyOnly previous desired =
  cloudCollectionEligible previous
    && previous ^. #lifecycle == Protect
    && desired ^. #lifecycle == DeleteWhenUnreferenced
    && previous == (desired & #lifecycle .~ Protect)

-- Called only by the explicit teardown command, never ordinary bootstrap.
-- This is a separately reviewed policy transition, not deletion authority.
compileCloudCollectionPolicy :: ScopeDeclaration -> Either Text ScopeDeclaration
compileCloudCollectionPolicy scope = do
  unless
    (scopeKind (scopeId scope) == Platform && nameText (scopeName (scopeId scope)) == "cloud")
    (Left "cloud teardown policy requires the accepted platform cloud scope")
  let revise (Managed resource)
        | cloudCollectionEligible resource
            && resource ^. #lifecycle == Protect =
            Managed (resource & #lifecycle .~ DeleteWhenUnreferenced)
      revise other = other
  updated <-
    first
      (T.pack . show)
      ( mkScopeDeclaration
          (scopeId scope)
          [bundle {declarations = map revise (declarations bundle)} | bundle <- scopeBundles scope]
      )
  pure
    ( withScopeOverrides
        (Map.insert "cloud.teardown.policy" "1" (scopeOverrides scope))
        (maybe updated (`withScopeConfigDigest` updated) (scopeConfigDigest scope))
    )

-- The whole registration bundle remains the ownership authority. Omission is a
-- separate exact URN set in protocol v2; legacy payloads reject that version.
encodeCloudCollectionBundle :: ByteString -> [Text] -> Either Text ByteString
encodeCloudCollectionBundle ordinary selected = do
  value <- first T.pack (eitherDecodeStrict' ordinary)
  registrations <-
    first
      T.pack
      ( Data.Aeson.Types.parseEither
          (withObject "cloud declaration bundle" (.: "registrations"))
          value
      )
  unless
    (not (null selected) && length selected == Set.size (Set.fromList selected))
    (Left "cloud collection requires distinct exact URNs")
  chosen <-
    traverse
      ( \urn -> case [ registration
                     | registration <- registrations
                     , registrationPulumiUrn registration == urn
                     ] of
          [registration]
            | registrationClass registration == ManagedRegistration
                && registrationPulumiType registration `elem` cloudCollectionTypes ->
                Right registration
          _ -> Left "cloud collection targets an unsupported or unowned registration"
      )
      selected
  case value of
    Object fields ->
      canonicalValue
        ( Object
            ( Data.Aeson.KeyMap.insert
                "version"
                (toJSON (2 :: Int))
                (Data.Aeson.KeyMap.insert "collections" (toJSON chosen) fields)
            )
        )
    _ -> Left "cloud declaration bundle is not an object"

-- Preserve ordinary identity bytes. A collection's effective program includes
-- its exact omission set, so another operator/mode cannot reuse its saved plan.
cloudCollectionProgramDigest :: ContentDigest -> ByteString -> Either Text ContentDigest
cloudCollectionProgramDigest original bytes = do
  value <- first T.pack (eitherDecodeStrict' bytes)
  (version, selected) <-
    first
      T.pack
      ( Data.Aeson.Types.parseEither
          ( withObject
              "cloud declaration bundle"
              ( \fields ->
                  (,)
                    <$> fields .: "version"
                    <*> fields .:? "collections" .!= []
              )
          )
          value
      )
  case (version :: Int) of
    1 | null (selected :: [NativeRegistration]), Object fields <- value, not (Data.Aeson.KeyMap.member "collections" fields) -> Right original
    2 | not (null selected) -> do
      canonical <- canonicalValue (toJSON (sort selected))
      pure (contentDigest (TE.encodeUtf8 (digestText original) <> canonical))
    _ -> Left "unsupported cloud collection program identity"

-- GCE deletion protection is separate native authority; teardown never clears it.
validateCloudCollectionProtection :: [NativeRegistration] -> ByteString -> Either Text ()
validateCloudCollectionProtection selected bytes = do
  value <- first T.pack (eitherDecodeStrict' bytes)
  resources <-
    first
      T.pack
      ( Data.Aeson.Types.parseEither
          (withObject "stack export" (\root -> root .: "deployment" >>= withObject "deployment" (.: "resources")))
          value
      )
  forM_ selected $ \registration -> do
    let matching =
          [ fields
          | Object fields <- resources
          , Data.Aeson.KeyMap.lookup "urn" fields == Just (String (registrationPulumiUrn registration))
          ]
    fields <- case matching of
      [one] -> Right one
      _ -> Left "cloud collection needs exactly one current native resource"
    when
      (Data.Aeson.KeyMap.lookup "protect" fields == Just (Bool True))
      (Left "cloud collection cannot clear native Pulumi protection")
    when (registrationPulumiType registration == "gcp:compute/instance:Instance") $ do
      let unprotected = case Data.Aeson.KeyMap.lookup "inputs" fields of
            Just (Object inputs) -> Data.Aeson.KeyMap.lookup "deletionProtection" inputs == Just (Bool False)
            _ -> False
      unless unprotected (Left "VM collection requires separately reviewed native deletionProtection=false; teardown cannot clear it")

-- Bind the selected native stack entry, including physical ID and protection,
-- to its saved plan. Each entry must still be the retained incarnation the
-- review proved, keyed by URN. This is a fresh guard repeated at preparation,
-- preflight and immediately before execution; it is not a provider atomic ID
-- CAS and cannot exclude an external writer racing the native call itself.
cloudCollectionPhysicalDigest :: ContentDigest -> Map.Map Text PhysicalIdentity -> [NativeRegistration] -> ByteString -> Either Text ContentDigest
cloudCollectionPhysicalDigest program retained selected bytes = do
  unless (not (null selected)) (Left "cloud collection has no selected native registration")
  validateCloudCollectionProtection selected bytes
  value <- first T.pack (eitherDecodeStrict' bytes)
  resources <-
    first
      T.pack
      ( Data.Aeson.Types.parseEither
          (withObject "stack export" (\root -> root .: "deployment" >>= withObject "deployment" (.: "resources")))
          value
      )
  entries <-
    traverse
      ( \registration -> case [ Object fields
                              | Object fields <- resources
                              , Data.Aeson.KeyMap.lookup "urn" fields == Just (String (registrationPulumiUrn registration))
                              ] of
          [one@(Object fields)] -> do
            let urn = registrationPulumiUrn registration
            expected <-
              maybe
                (Left "cloud collection lacks its reviewed retained physical identity")
                Right
                (Map.lookup urn retained)
            current <- case Data.Aeson.KeyMap.lookup "id" fields of
              Just (String identifier) -> mkPhysicalIdentity identifier
              Nothing -> mkPhysicalIdentity urn
              Just Null -> mkPhysicalIdentity urn
              Just _ -> Left "collection physical binding has a malformed native ID"
            unless
              (current == expected)
              (Left "cloud collection target is no longer the reviewed retained incarnation")
            Right one
          _ -> Left "collection physical binding is missing or ambiguous"
      )
      (sort selected)
  canonical <- canonicalValue (toJSON entries)
  pure (contentDigest ("cloud-collection-physical-v1:" <> TE.encodeUtf8 (digestText program) <> canonical))
