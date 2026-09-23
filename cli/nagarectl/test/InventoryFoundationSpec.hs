module InventoryFoundationSpec (inventoryFoundationTests) where

import Data.Generics.Labels ()
import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Bootstrap (compileBootstrapStamp)
import Nagare.Inventory.Components.Foundation
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.KubernetesSources (validateSuppliedKubernetesMembers)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes
import Nagare.Resource.Policy (RecoveryClass (Idempotent))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Test.Tasty
import Test.Tasty.HUnit
import System.FilePath ((</>))

inventoryFoundationTests :: TestTree
inventoryFoundationTests = testGroup "cluster foundation inventory"
  [ testCase "platform namespaces and personal Job quota form one bound bundle" $ do
      (bundle, native) <- compileFoundation foundationInput >>= expectRight
      length (declarations bundle) @?= 3
      Map.size native @?= 3
      let resources = [member | Managed member <- declarations bundle]
      _ <- expectRight (validateSuppliedKubernetesMembers resources native)
      let quota = [member | member <- resources, member ^. #address == Kubernetes fixtureCluster "" (known "resourcequota") (Just (known "personal")) (known "nagare-terminating-jobs")]
      length quota @?= 1
      case [member | member <- resources, member ^. #address == Kubernetes fixtureCluster "" (known "namespace") Nothing (known "personal")] of
        [personal] -> do
          let changed = object ["apiVersion" .= ("v1" :: Text), "kind" .= ("Namespace" :: Text),
                "metadata" .= object ["name" .= ("personal" :: Text), "labels" .= object ["nagare.dev/app-namespace" .= ("false" :: Text)]]]
              changedBytes = ok (canonicalValue changed)
              changedInput = KubernetesInput (personal ^. #identity) fixtureOwner fixtureCluster changed
                (contentDigest changedBytes) (personal ^. #lifecycle) (personal ^. #dataPolicy)
                (personal ^. #sensitivity) (personal ^. #source)
          (changedDeclaration, _) <- expectRight (bindKubernetesObject changedInput)
          assertBool "namespace label change did not change desired specification"
            (changedDeclaration ^. #spec /= personal ^. #spec)
        _ -> assertFailure "personal Namespace declaration missing"
      let binding = ContextBinding (ok (mkContextId "fixture")) (known "project")
          scope = ok (mkScopeDeclaration fixtureOwner [bundle])
          snapshot = ok (mkScopeSnapshot binding Map.empty Map.empty)
      assertBool "foundation scope failed claim validation" (either (const False) (const True)
        (composeInventory snapshot (ReplaceScope scope :| [])))
  , testCase "missing quota source refuses before any native mutation" $ do
      result <- compileFoundation (foundationInput {foundationQuotaPath = "../../cluster/bootstrap/missing-quota.yaml"})
      assertBool "missing quota was accepted" (either (const True) (const False) result)
  , testCase "reviewed release marker waits for every foundation resource and operation" $ do
      (foundationBundle, _) <- compileFoundation foundationInput >>= expectRight
      let quotaId = case [member ^. #identity | Managed member <- declarations foundationBundle,
            member ^. #address == Kubernetes fixtureCluster "" (known "resourcequota")
              (Just (known "personal")) (known "nagare-terminating-jobs")] of
            [resource] -> resource
            _ -> error "foundation quota is missing"
          operationId = mintResourceId fixtureOwner (ok (mkLogicalKey "bootstrap")) (known "proof")
          proof = DeclaredOperation operationId (quotaId :| []) [] Idempotent PublishRelease
          baseScope = ok (mkScopeDeclaration fixtureOwner [foundationBundle {operations = [proof]}])
          binding = ContextBinding (ok (mkContextId "fixture")) (known "project")
          snapshot = ok (mkScopeSnapshot binding Map.empty Map.empty)
          base = ok (composeInventory snapshot (ReplaceScope baseScope :| []))
          marker = object ["apiVersion" .= ("v1" :: Text), "kind" .= ("ConfigMap" :: Text),
            "metadata" .= object ["name" .= ("nagare-platform-version" :: Text),
              "namespace" .= ("nagare-system" :: Text)],
            "data" .= object ["version" .= ("0.4.0" :: Text),
              "installedAt" .= ("2026-09-22T00:00:00Z" :: Text)]]
      (stampScope, native) <- expectRight (compileBootstrapStamp fixtureCluster marker base)
      let stampMembers = [resource | bundle <- scopeBundles stampScope,
            Managed resource <- declarations bundle]
      case stampMembers of
        [stamp] -> do
          let required = [resource ^. #identity | Managed resource <- inventoryDeclarations (candidateInventory base)]
          all (\resource -> OrderedAfter resource `elem` stamp ^. #dependencies) (operationId : required)
            @?= True
          Map.member (stamp ^. #identity) native @?= True
        _ -> assertFailure "bootstrap has no unique marker"
      _ <- expectRight (composeInventory snapshot (candidateChanges base <> (ReplaceScope stampScope :| [])))
      let accepted = ok (mkScopeSnapshot binding (Map.fromList
            [(fixtureOwner, (ok (mkScopeGeneration 1), baseScope)),
             (scopeId stampScope, (ok (mkScopeGeneration 1), stampScope))]) Map.empty)
          rerun = ok (composeInventory accepted (ReplaceScope baseScope :| []))
      (nextStamp, _) <- expectRight (compileBootstrapStamp fixtureCluster marker rerun)
      _ <- expectRight (composeInventory accepted (candidateChanges rerun <> (ReplaceScope nextStamp :| [])))
      pure ()
  , testCase "granted namespace contributions materialize once for shared callers" $ do
      let appA = ok (mkScopeId Application "a")
          appB = ok (mkScopeId Application "b")
          input = foundationInput {foundationGrantedScopes = [appA, appB]}
          request = RegisterNamespace fixtureOwner fixtureCluster (known "sandbox") (ok (mkLogicalKey "sandbox"))
          consumer scopeId = ok (mkScopeDeclaration scopeId [ResourceBundle [] [] [] [request] [] []])
          binding = ContextBinding (ok (mkContextId "fixture")) (known "project")
          snapshot = ok (mkScopeSnapshot binding Map.empty Map.empty)
      (bundle, _) <- compileFoundation input >>= expectRight
      let platformScope = ok (mkScopeDeclaration fixtureOwner [bundle])
          candidate = ok (composeInventory snapshot (ReplaceScope platformScope :| [ReplaceScope (consumer appA), ReplaceScope (consumer appB)]))
          declarations = inventoryDeclarations (candidateInventory candidate)
      native <- expectRight (compileContributedNamespaces declarations)
      Map.size native @?= 1
      let resources = [member | Managed member <- declarations, member ^. #executor == KubernetesExecutor]
      _ <- expectRight (validateSuppliedKubernetesMembers resources native)
      pure ()
  ]

foundationInput :: FoundationInput
foundationInput = FoundationInput fixtureOwner fixtureCluster ("../../cluster/bootstrap/job-runs" </> "resourcequota.yaml") []

fixtureOwner :: ScopeId
fixtureOwner = ok (mkScopeId Platform "foundation")

fixtureCluster :: ResourceId
fixtureCluster = mintResourceId fixtureOwner (ok (mkLogicalKey "cluster")) (known "cluster")

known :: Text -> Name
known = ok . mkName

ok :: Show e => Either e a -> a
ok = either (error . show) id

expectRight :: Show e => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> pure (error "unreachable")) pure
