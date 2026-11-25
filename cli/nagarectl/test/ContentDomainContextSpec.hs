-- | EP-285 M2: a context lists its content domains, and a cloud context's
-- Pulumi config and reviewed cloud catalog carry one zone per domain.
module ContentDomainContextSpec (contentDomainContextTests) where

import Data.ByteString.Char8 qualified as BC
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Context.Posture (WebRules (..), directPosture)
import Nagare.Dsl.ContentDomain (contentDomainSlug, contentDomainText)
import Nagare.Dsl.Prelude
import Nagare.Init (renderTargetEnv, seedKeysFor, servedContentDomains)
import Nagare.Inventory.Cloud
import Nagare.Resource.Types (mkName, nameText)
import Nagare.Target (TargetProfile, mkContextName, parseContextEnv, profileFromContextMap, pulumiEnvFor, renderContextShellEnv)
import Nagare.Target.ContentDomains
import Nagare.Test.Support.Profiles (initProfile)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

contentDomainContextTests :: TestTree
contentDomainContextTests =
  testGroup
    "content domain context"
    [ testCase "a context lists content domains in order and writes them back" $ do
        let ctx = Map.fromList [("NAGARE_BASE_DOMAIN", "apps.example.com"), ("NAGARE_CONTENT_DOMAINS", " docs.example.org,share.example.net ")]
            profile = profileFromContextMap ctx
        map contentDomainText (profile ^. #contentDomains) @?= ["docs.example.org", "share.example.net"]
        assertBool "the context file keeps the list" ("export NAGARE_CONTENT_DOMAINS=docs.example.org,share.example.net" `T.isInfixOf` renderTargetEnv profile)
        profileFromContextMap (parseContextEnv (renderTargetEnv profile)) ^. #contentDomains @?= profile ^. #contentDomains
        parseContentDomains "apps.example.com" Map.empty @?= Right []
        parseContentDomains "apps.example.com" (Map.fromList [("NAGARE_CONTENT_DOMAINS", " ")]) @?= Right []
    , testCase "a context with no content domain writes none" $ do
        assertBool "an unset list is written" (not ("NAGARE_CONTENT_DOMAINS" `T.isInfixOf` renderTargetEnv initProfile))
    , testCase "a domain that shares the login cookie's scope, repeats or is not a plain name is refused" $ do
        let refused raw = parseContentDomains "apps.example.com" (Map.fromList [("NAGARE_CONTENT_DOMAINS", raw)])
            refusedWith raw fragment = case refused raw of
              Left reason -> assertBool (T.unpack (raw <> " refused for: " <> reason)) (fragment `T.isInfixOf` reason)
              Right _ -> assertFailure (T.unpack raw <> " was accepted")
        refusedWith "apps.example.com" "equals the base domain"
        refusedWith "docs.apps.example.com" "is under the base domain"
        refusedWith "example.com" "contains the base domain"
        refusedWith "docs.example.org,docs.example.org" "twice"
        refusedWith "a-b.example.org,a.b-example.org" "collide"
        refusedWith "*.docs.example.org" "wildcard"
        refusedWith "localhost" "two labels"
        refusedWith (T.replicate 45 "x" <> ".org") "48 characters"
        assertBool "a sibling of the base domain is a separate cookie scope" (not (isLeft (refused "docs.example.org")))
    , testCase "a direct cloud context seeds its content domains; a tunnel context and an empty list seed none" $ do
        let profile = withDomains "docs.example.org,share.example.net"
            tunnel = directPosture & #webRules .~ WebRulesAbsent
        lookup "nagare:contentDomains" (seedKeysFor profile directPosture "") @?= Just "docs.example.org,share.example.net"
        lookup "nagare:contentDomains" (seedKeysFor profile tunnel "") @?= Nothing
        lookup "nagare:contentDomains" (seedKeysFor initProfile directPosture "") @?= Nothing
        servedContentDomains profile tunnel @?= []
    , testCase "the shell environment exports the list" $ do
        let profile = withDomains "docs.example.org"
        name <- either (assertFailure . T.unpack) pure (mkContextName "acme")
        let rendered = renderContextShellEnv name profile (pulumiEnvFor "/state" "acme" profile)
        assertBool "the export is missing" ("export NAGARE_CONTENT_DOMAINS='docs.example.org'" `T.isInfixOf` rendered)
    , testCase "the cloud catalog instantiates one zone, two records and one grant per domain above every other layer" $ do
        catalog <- BC.readFile "../../infra/pulumi/resource-catalog.json" >>= expectRight . decodeCloudCatalog
        let profile = withDomains "docs.example.org"
            slugs = map contentDomainSlug (servedContentDomains profile directPosture)
        instantiated <- expectRight (withContentDomains slugs catalog)
        let entries = catalogContentDomains instantiated
            others = filter (`notElem` entries) (selectedCloudCatalog True True True True True instantiated)
        map (nameText . catalogNativeName) entries
          @?= [ "nagare-content-docs-example-org"
              , "nagare-content-docs-example-org-zone"
              , "nagare-content-docs-example-org-iam-dns-zone"
              , "nagare-content-docs-example-org-apex"
              , "nagare-content-docs-example-org-wildcard"
              ]
        assertBool "a content domain entry is not selected" (all (`elem` selectedCloudCatalog False False False False False instantiated) entries)
        assertBool "a content domain layer is not above every other" (minimum (map catalogLayer entries) > maximum (map catalogLayer others))
        stack <- expectRight (mkName "acme")
        urns <- expectRight (traverse (cloudCatalogUrn stack instantiated) entries)
        assertBool "the zone is not a child of its component" ("::nagare:env:NagareContentDomain$gcp:dns/managedZone:ManagedZone::nagare-content-docs-example-org-zone" `T.isInfixOf` (urns !! 1))
        none <- expectRight (withContentDomains [] catalog)
        catalogContentDomains none @?= []
        contentDomainZoneName (head (profile ^. #contentDomains)) @?= "nagare-content-docs-example-org"
    , testCase "a content domain's delegation matches only when public resolvers name the zone's servers" $ do
        let zone = Right ["ns-cloud-a1.googledomains.com.", "ns-cloud-a2.googledomains.com."]
        contentDelegationProblem zone [["ns-cloud-a2.googledomains.com", "NS-CLOUD-A1.googledomains.com."], []] @?= Nothing
        assertBool "no answer is a match" (isJust (contentDelegationProblem zone [[], [], []]))
        case contentDelegationProblem zone [["ns1.registrar.example"]] of
          Just problem -> assertBool (T.unpack problem) ("ns1.registrar.example" `T.isInfixOf` problem)
          Nothing -> assertFailure "another registrar's servers matched"
        contentDelegationProblem (Left "gcloud could not describe") [["x"]] @?= Just "gcloud could not describe"
        assertBool "the slug check" (not ("." `isInfixOf` T.unpack (contentDomainZoneName (head (withDomains "a.b.example" ^. #contentDomains)))))
    ]
  where
    withDomains :: Text -> TargetProfile
    withDomains raw = initProfile & #contentDomains .~ either (error . T.unpack) id (parseContentDomains (initProfile ^. #baseDomain) (Map.fromList [("NAGARE_CONTENT_DOMAINS", raw)]))
    expectRight :: Either Text a -> IO a
    expectRight = either (assertFailure . T.unpack) pure
