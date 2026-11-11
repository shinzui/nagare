-- | EP-249: a rendered configuration carries a program's exact stdout; the
-- deploy path decodes it with the same decoder as @-f@; a document is
-- untrusted input; and a delegated deployer's process runs no config program.
module RenderedSpec (renderedTests) where

import ApplicationSpec (multiApp)
import Control.Exception (bracket_)
import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy (toStrict)
import Data.Either (isLeft)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Config (encodeApplication, encodeServerSite, encodeStaticSite, encodeWorker)
import Nagare.Dsl.Load
import Nagare.Dsl.Prelude
import ServerSpec (notesApp)
import StaticSpec (notesSite)
import System.Directory (doesFileExist)
import System.Environment (setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit
import WorkerSpec (richWorker)

renderedTests :: TestTree
renderedTests =
  testGroup
    "Rendered"
    [ testCase "an application, a worker and both sites decode from their documents exactly as from the program's output" $ do
        let app = toStrict (encodeApplication multiApp)
            worker = toStrict (encodeWorker richWorker)
            static = toStrict (encodeStaticSite notesSite)
            server = toStrict (encodeServerSite notesApp)
        (decodeApplication . snd =<< roundTrip RenderedApplication [RenderedApplication] app) @?= decodeApplication app
        (decodeWorker . snd =<< roundTrip RenderedWorker [RenderedWorker] worker) @?= decodeWorker worker
        (decodeSite . snd =<< roundTrip RenderedStaticSite sites static) @?= decodeSite static
        (decodeSite . snd =<< roundTrip RenderedServerSite sites server) @?= decodeSite server
        fmap fst (roundTrip RenderedServerSite sites server) @?= Right RenderedServerSite
    , testCase "the exact bytes survive: a trailing newline, reordered keys, non-ASCII text" $
        forM_ ["{\"kind\":\"Application\"}\n", "{ \"b\" : 1,\n  \"a\" : \"\195\169t\195\169\" }\n\n", "  \t{}  "] $ \stdout ->
          fmap snd (roundTrip RenderedApplication [RenderedApplication] stdout) @?= Right stdout
    , testCase "alternate outer JSON escaping decodes to the same bytes" $ do
        document <- either (assertFailure . show) pure (renderedDocument "0.18.0" RenderedApplication "\195\169")
        let escaped = BC.pack (Text.unpack (Text.replace "\"config\":\"\233\"" "\"config\":\"\\u00e9\"" (TE.decodeUtf8 document)))
        assertBool "the escape was rewritten" (escaped /= document)
        fmap snd (decodeRendered "0.18.0" [RenderedApplication] escaped) @?= Right "\195\169"
    , testCase "a one-byte config edit, a wrong kind, a newer contract or Nagare version and malformed JSON are refused" $ do
        document <- either (assertFailure . show) pure (renderedDocument "0.18.0" RenderedApplication "{\"kind\":\"Application\"}")
        let edit from to = BC.pack (Text.unpack (Text.replace from to (TE.decodeUtf8 document)))
            refused = assertBool "refused" . isLeft
        refused (decodeRendered "0.18.0" [RenderedApplication] (edit "Application\\\"}" "Applicatiom\\\"}"))
        refused (decodeRendered "0.18.0" [RenderedWorker] document)
        refused (decodeRendered "0.18.0" [RenderedApplication] (edit "\"contractVersion\":1" "\"contractVersion\":2"))
        refused (decodeRendered "0.17.9" [RenderedApplication] document)
        fmap snd (decodeRendered "0.19.0" [RenderedApplication] document) @?= Right "{\"kind\":\"Application\"}"
        refused (decodeRendered "0.18.0" [RenderedApplication] "{\"contractVersion\":1")
        refused (decodeRendered "0.18.0" [RenderedApplication] (edit "\"document\":\"rendered-application\"" "\"document\":\"rendered-worker\""))
    , testCase "a document is data: unknown members are refused and a config naming a path or command is never acted on" $ do
        document <- either (assertFailure . show) pure (renderedDocument "0.18.0" RenderedApplication "{\"kind\":\"Application\",\"run\":\"rm -rf /\",\"file\":\"/etc/passwd\"}")
        let extra = BC.pack (Text.unpack (Text.replace "{\"config\"" "{\"command\":\"touch /tmp/x\",\"config\"" (TE.decodeUtf8 document)))
        assertBool "unknown member" (isLeft (decodeRendered "0.18.0" [RenderedApplication] extra))
        case decodeApplication . snd =<< decodeRendered "0.18.0" [RenderedApplication] document of
          Left _ -> pure ()
          Right _ -> assertFailure "a config that is not an Application decoded"
    , testCase "every input to the decoders either decodes or is a LoadError" $
        forM_ (take 400 (inputs (toStrict (encodeApplication multiApp)))) $ \input -> do
          let results = [void (decodeApplication input), void (decodeWorker input), void (decodeSite input), void (decodeRendered "0.18.0" [minBound .. maxBound] input)]
          forM_ results $ \result -> result `seq` pure ()
    , testCase "a deployer's process refuses every config program before starting one" $
        withSystemTempDirectory "ep249-refusal" $ \directory -> do
          let marker = directory </> "ran"
              program = directory </> "Config.hs"
          BS.writeFile program (BC.pack ("import System.IO\nmain :: IO ()\nmain = writeFile " <> show marker <> " \"ran\"\n"))
          bracket_ (setEnv "NAGARE_DEPLOYER" "kotei") (unsetEnv "NAGARE_DEPLOYER") $ do
            results <-
              sequence
                [ void <$> loadApplication program
                , void <$> loadWorker program
                , void <$> loadSite program
                , void <$> loadStaticSite program
                , void <$> loadServerSite program
                , void <$> loadDeployment program
                , void <$> loadTask program
                , void <$> loadJob program
                , void <$> loadBroker program
                , void <$> loadDatabase program
                , void <$> loadAppDatabases program
                , void <$> runConfigWith defaultConfigTimeout program
                ]
            forM_ results (@?= Left (ConfigProgramRefused program))
          doesFileExist marker >>= (@?= False)
    ]
  where
    sites = [RenderedStaticSite, RenderedServerSite]
    roundTrip kind accepted stdout = renderedDocument "0.18.0" kind stdout >>= decodeRendered "0.18.0" accepted
    -- Truncations and single-byte corruptions of a valid config.
    inputs bytes =
      [BS.take n bytes | n <- [0, 7 .. BS.length bytes]]
        <> [BS.take n bytes <> BS.singleton byte <> BS.drop (n + 1) bytes | n <- [0, 13 .. BS.length bytes], byte <- [0, 34, 123, 255]]
