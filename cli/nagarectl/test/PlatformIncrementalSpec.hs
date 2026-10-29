-- | EP-225 M1: a platform scope compiled from another release workspace keeps
-- its accepted revision; one whose deployment meaning changed does not.
module PlatformIncrementalSpec (platformIncrementalTests) where

import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Prelude
import Nagare.Inventory.Bootstrap (bootstrapPreservedScopeVectorDigest, bootstrapScopeVectorDigest)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Store (ScopeRevision (..))
import Nagare.Resource.DeploymentMeaning (sameDeploymentMeaning)
import Nagare.Resource.Inventory (Declaration (..), ManagedResource, ResourceBundle (..), ScopeChange (ReplaceScope), ScopeDeclaration, candidateGenerations, composeInventory, mkScopeDeclaration, mkScopeSnapshot)
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (Retain), Sensitivity (Public))
import Nagare.Resource.Types qualified as Resource
import Nagare.Resource.Wire (canonicalValue, encodeCanonicalScope)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

platformIncrementalTests :: TestTree
platformIncrementalTests =
  testGroup
    "PlatformIncremental (EP-225 M1)"
    [ testCase "a scope compiled from another workspace keeps its accepted revision and vector" $ do
        let accepted = scopeAt "/state/platform/nagare-0.11.0-aaaa/cluster/observability/vmks.yaml" "value"
            moved = scopeAt "/state/platform/nagare-0.11.1-bbbb/cluster/observability/vmks.yaml" "value"
            snapshot = ok (mkScopeSnapshot binding (Map.singleton owner (generation, accepted)) Map.empty)
            candidate = ok (composeInventory snapshot (ReplaceScope moved :| []))
        assertBool "the fixture's bytes do not differ" (encodeCanonicalScope accepted /= encodeCanonicalScope moved)
        assertBool "moved declarations changed meaning" (sameDeploymentMeaning accepted moved)
        bootstrapPreservedScopeVectorDigest snapshot candidate
          @?= Right (bootstrapScopeVectorDigest (Map.singleton owner (ScopeRevision generation (contentDigest (encodeCanonicalScope accepted)))))
    , testCase "a scope whose meaning changed takes the candidate's revision" $ do
        let accepted = scopeAt "/state/platform/nagare-0.11.0-aaaa/cluster/observability/vmks.yaml" "value"
            changed = scopeAt "/state/platform/nagare-0.11.1-bbbb/cluster/observability/vmks.yaml" "other"
            snapshot = ok (mkScopeSnapshot binding (Map.singleton owner (generation, accepted)) Map.empty)
            candidate = ok (composeInventory snapshot (ReplaceScope changed :| []))
            next = Map.lookup owner (candidateGenerations candidate)
        assertBool "a changed scope kept its generation" (next /= Just generation)
        bootstrapPreservedScopeVectorDigest snapshot candidate
          @?= Right (bootstrapScopeVectorDigest (Map.fromList [(owner, ScopeRevision revision (contentDigest (encodeCanonicalScope changed))) | Just revision <- [next]]))
    ]

owner :: Resource.ScopeId
owner = ok (Resource.mkScopeId Resource.Platform "observability-vmks")

generation :: Resource.ScopeGeneration
generation = ok (Resource.mkScopeGeneration 3)

binding :: Resource.ContextBinding
binding = Resource.ContextBinding (ok (Resource.mkContextId "incremental")) (ok (Resource.mkName "project"))

scopeAt :: Text -> Text -> ScopeDeclaration
scopeAt path value = ok (mkScopeDeclaration owner [ResourceBundle [Managed member] [] [] [] [] []])
  where
    member :: ManagedResource
    (member, _ :: ByteString) =
      ok
        ( bindKubernetesObject
            ( KubernetesInput
                (Resource.mintResourceId owner (ok (Resource.mkLogicalKey "config")) (ok (Resource.mkName "configmap")))
                owner
                cluster
                object
                (contentDigest (ok (canonicalValue object)))
                Retain
                Stateless
                Public
                (Resource.SourceLocation path "config")
            )
        )
    foundation = ok (Resource.mkScopeId Resource.Platform "foundation")
    cluster = Resource.mintResourceId foundation (ok (Resource.mkLogicalKey "cluster")) (ok (Resource.mkName "resource"))
    object =
      Aeson.object
        [ "apiVersion" Aeson..= ("v1" :: Text)
        , "kind" Aeson..= ("ConfigMap" :: Text)
        , "metadata" Aeson..= Aeson.object ["name" Aeson..= ("vmks" :: Text), "namespace" Aeson..= ("nagare-system" :: Text)]
        , "data" Aeson..= Aeson.object ["key" Aeson..= value]
        ]

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
