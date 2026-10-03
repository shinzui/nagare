{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLabels #-}
module Main where
import Data.Aeson (object,(.=))
import Data.Aeson qualified
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty((:|)))
import Data.Map.Strict qualified as Map
import Data.Text qualified
import Data.Time (UTCTime(..),fromGregorian)
import Nagare.Cli.Inventory.Planning (inventoryPlanRegistryWithNative)
import Nagare.Cli.Runtime.Target (activeTarget,resolvePlatformWorkspace)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Command qualified as I
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput(..))
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Static.Release
import System.Environment (getArgs)
ok :: Show e => Either e a -> a
ok=either (error.show) id
main :: IO ()
main=do
 [output]<-getArgs
 active<-activeTarget (Just "local")
 (_,workspace)<-resolvePlatformWorkspace (active ^. #contextName)
 snapshot<-I.loadTargetSnapshotReadOnly active
 let owner=ok(mkScopeId Standalone "mp23-release-cleanup-proof")
     cluster=mintResourceId (ok(mkScopeId Platform "cluster")) (ok(mkLogicalKey "cluster")) (ok(mkName "cluster"))
     source=SourceLocation "/tmp/mp23-independent-cleanup-native/Fixture.hs" "independent cleanup acceptance"
     logValue=StaticReleaseLog (Just "r1") [StaticRelease ("r"<>(Data.Text.pack (show n))) "mp23-cleanup-proof" "personal" "fixture" "fixture" "https://example.invalid" Nothing (UTCTime(fromGregorian 2026 10 2) 0) | n<-[4,3,2,1::Int]]
     history=renderReleaseConfigMap "mp23-cleanup-proof" "personal" logValue
     adjacent=ok(canonicalValue(object["apiVersion".=("v1"::Text),"kind".=("ConfigMap"::Text),"metadata".=object["name".=("mp23-cleanup-adjacent"::Text),"namespace".=("personal"::Text)],"data".=object["sentinel".=("independent-cleanup-preserve"::Text)]]))
     bind key bytes = let value=ok(Data.Aeson.eitherDecodeStrict bytes); rid=mintResourceId owner (ok(mkLogicalKey key)) (ok(mkName key)) in ok(bindKubernetesObject(KubernetesInput rid owner cluster value (contentDigest bytes) DeleteWhenUnreferenced Stateless Private source))
     pairs=[bind "history" history,bind "adjacent" adjacent]
     scope=withScopeConfigDigest(contentDigest "independent cleanup fixture") $ withScopeOverrides(Map.singleton "fixture.purpose" "release-history-cleanup") $ ok(mkScopeDeclaration owner [ResourceBundle (map (Managed . fst) pairs) [] [] [] [] []])
     candidate=ok(composeInventory snapshot (ReplaceScope scope:|[]))
     native=Map.fromList [(m ^. #identity,(m,b))|(m,b)<-pairs]
 I.planInventoryCandidateWith (inventoryPlanRegistryWithNative active workspace native) active candidate output
