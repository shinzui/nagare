-- | Application responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Application
  ( appTests
  , deploymentsTests
  , staticServiceYaml
  )
where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.App
  ( AppSummary (..)
  , LogTarget (..)
  , extractAppSummaries
  , extractAppSummary
  , formatAppList
  , logArgs
  , parseServiceNames
  )
import Nagare.App.Deployments (appConfigMapName, revisionForTag)
import Nagare.Dsl.Prelude hiding ((<.>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit
  ( assertBool
  , assertFailure
  , testCase
  , (@?=)
  )

-- ---------------------------------------------------------------------------
-- Nagare.App.Deployments (EP-31)

deploymentsTests :: [TestTree]
deploymentsTests =
  [ testCase "appConfigMapName prefixes the app name" $
      appConfigMapName "notes" @?= "nagare-app-deployments-notes"
  , testCase "revisionForTag matches the revision whose image ends with :tag" $
      revisionForTag "20260610-110000" revisionsJSON @?= Just "notes-00002"
  , testCase "revisionForTag returns Nothing when no revision carries the tag" $
      revisionForTag "20260101-000000" revisionsJSON @?= Nothing
  , testCase "revisionForTag returns Nothing on malformed JSON" $
      revisionForTag "x" "{not json" @?= Nothing
  ]
  where
    revisionsJSON =
      BC.pack $
        concat
          [ "{\"items\":["
          , "{\"metadata\":{\"name\":\"notes-00001\"},\"spec\":{\"containers\":[{\"image\":\"gcr.io/p/notes:20260610-100000\"}]}},"
          , "{\"metadata\":{\"name\":\"notes-00002\"},\"spec\":{\"containers\":[{\"image\":\"gcr.io/p/notes:20260610-110000\"}]}}"
          , "]}"
          ]

-- ---------------------------------------------------------------------------
-- Nagare.App (EP-30)

appTests :: [TestTree]
appTests =
  [ testGroup
      "parseServiceNames"
      [ testCase "strips the resource prefix and drops blanks" $
          parseServiceNames "service.serving.knative.dev/notes\n\nservice.serving.knative.dev/blog\n"
            @?= ["notes", "blog"]
      , testCase "tolerates already-bare names" $
          parseServiceNames "notes\nblog\n" @?= ["notes", "blog"]
      ]
  , testGroup
      "logArgs"
      [ testCase "service selector, user-container, default no follow/tail" $
          logArgs (LogTarget "personal" "notes" Nothing False Nothing)
            @?= ["logs", "-l", "serving.knative.dev/service=notes", "-n", "personal", "-c", "user-container"]
      , testCase "adds --tail and --follow" $
          logArgs (LogTarget "personal" "notes" Nothing True (Just 50))
            @?= [ "logs"
                , "-l"
                , "serving.knative.dev/service=notes"
                , "-n"
                , "personal"
                , "-c"
                , "user-container"
                , "--tail"
                , "50"
                , "--follow"
                ]
      , testCase "pins the revision selector when given" $
          logArgs (LogTarget "personal" "notes" (Just "notes-00003") False Nothing)
            @?= [ "logs"
                , "-l"
                , "serving.knative.dev/service=notes,serving.knative.dev/revision=notes-00003"
                , "-n"
                , "personal"
                , "-c"
                , "user-container"
                ]
      ]
  , testGroup
      "extractAppSummary"
      [ testCase "pulls name/url/ready/revision/image from a ksvc object" $
          extractAppSummary ksvcJSON
            @?= Right
              AppSummary
                { name = "notes"
                , url = Just "https://notes.personal.apps.example.com"
                , ready = Just True
                , latestRevision = Just "notes-00003"
                , image = Just "gcr.io/p/notes:20260610-120000"
                }
      , testCase "missing .metadata.name is a Left" $
          case extractAppSummary "{\"status\":{}}" of
            Left _ -> pure ()
            Right s -> assertFailure ("expected Left, got: " <> show s)
      , testCase "a list response yields one summary per item" $
          fmap (map (^. #name)) (extractAppSummaries ksvcListJSON) @?= Right ["notes"]
      ]
  , testGroup
      "formatAppList"
      [ testCase "aligns NAME/READY/URL and marks empty" $
          formatAppList [] @?= "(no apps)\n"
      , testCase "renders a row with ready and url" $ do
          let out = formatAppList [AppSummary "notes" (Just "https://x") (Just True) Nothing Nothing]
          assertBool "has header NAME" ("NAME" `T.isInfixOf` out)
          assertBool "has the app name" ("notes" `T.isInfixOf` out)
          assertBool "has ready True" ("True" `T.isInfixOf` out)
          assertBool "has url" ("https://x" `T.isInfixOf` out)
      ]
  ]
  where
    ksvcJSON =
      BC.pack $
        concat
          [ "{\"metadata\":{\"name\":\"notes\"},"
          , "\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"image\":\"gcr.io/p/notes:20260610-120000\"}]}}},"
          , "\"status\":{\"url\":\"https://notes.personal.apps.example.com\","
          , "\"latestReadyRevisionName\":\"notes-00003\","
          , "\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\"}]}}"
          ]
    ksvcListJSON =
      BC.pack ("{\"items\":[" <> BC.unpack ksvcJSON <> "]}")

-- ---------------------------------------------------------------------------
-- Nagare.Env.PreviewOverlay (EP-27 M2)

-- | A minimal static preview Service (no env/envFrom), as the static renderer
-- emits it. The overlay must add the four envFrom entries to its container.
staticServiceYaml :: ByteString
staticServiceYaml =
  BC.pack $
    unlines
      [ "apiVersion: serving.knative.dev/v1"
      , "kind: Service"
      , "metadata:"
      , "  name: demo-pr-42"
      , "  namespace: personal"
      , "spec:"
      , "  template:"
      , "    spec:"
      , "      containers:"
      , "      - image: gcr.io/p/demo:20260609-120000"
      , "        ports:"
      , "        - containerPort: 8080"
      ]
