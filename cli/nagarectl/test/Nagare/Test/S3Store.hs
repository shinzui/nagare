-- | EP-251 D2 and D3: the S3-compatible transport over an in-memory S3 that
-- implements ETag conditions, with lost acknowledgements, a racing writer,
-- paged listings and refused credentials; and the same stored bytes as the
-- GCS-shaped fake for the same history.
module Nagare.Test.S3Store
  ( s3StoreTests
  )
where

import Control.Concurrent (threadDelay)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import InventoryTransactionSpec (exerciseStore, fixtureBinding)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Store
import Nagare.Inventory.Store.Migrate (migrateStore)
import Nagare.Inventory.Store.ObjectOps
import Nagare.Inventory.Store.ObjectTarget
import Nagare.Inventory.Store.S3
import Nagare.Target (InventoryStoreKind (..), Mode (..), effectiveInventoryStore, objectInventoryStoreUrl)
import Nagare.Test.Support.Profiles (initProfile)
import Nagare.Test.World.ObjectStore (fakeObjectOps, fakeObjectState)
import Network.HTTP.Types (methodGet, methodPut)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Process (readProcessWithExitCode)
import Test.Tasty
import Test.Tasty.HUnit

s3StoreTests :: TestTree
s3StoreTests =
  testGroup
    "S3 store"
    [ testCase "an S3-backed inventory obeys the conditional store contract" $ do
        (ops, _, _) <- fakeS3 1000
        store <- newObjectStore ops fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
        exerciseStore store
    , testCase "create and replace refuse a present key and a changed ETag, leaving the object" $ do
        (ops, objects, _) <- fakeS3 1000
        first' <- putObject ops IfAbsent (ObjectName "head.json") "one"
        generation <- case first' of
          PutWritten g -> pure g
          other -> assertFailure (show other)
        putObject ops IfAbsent (ObjectName "head.json") "two" >>= (@?= PutPreconditionFailed)
        putObject ops (IfGenerationMatches generation) (ObjectName "head.json") "two" >>= \case
          PutWritten _ -> pure ()
          other -> assertFailure (show other)
        putObject ops (IfGenerationMatches generation) (ObjectName "head.json") "three" >>= (@?= PutPreconditionFailed)
        putObject ops (IfGenerationMatches generation) (ObjectName "missing.json") "x" >>= (@?= PutPreconditionFailed)
        fmap snd . Map.lookup "inventory/ctx/head.json" <$> readIORef objects >>= (@?= Just "two")
        Map.member "inventory/ctx/missing.json" <$> readIORef objects >>= (@?= False)
    , testCase "a lost acknowledgement is classified by reading the object back" $ do
        (ops, _, faults) <- fakeS3 1000
        writeIORef faults [LoseAcknowledgement]
        putObject ops IfAbsent (ObjectName "head.json") "one" >>= \case
          PutWritten _ -> pure ()
          other -> assertFailure ("a landed write with a lost reply was " <> show other)
        writeIORef faults [LoseRequest]
        putObject ops IfAbsent (ObjectName "other.json") "one" >>= \case
          PutNoEffect _ -> pure ()
          other -> assertFailure ("an unsent write was " <> show other)
    , testCase "a racing writer between read and replace makes the replace refuse" $ do
        (ops, _, faults) <- fakeS3 1000
        generation <-
          putObject ops IfAbsent (ObjectName "head.json") "one" >>= \case
            PutWritten g -> pure g
            other -> assertFailure (show other)
        writeIORef faults [RacingWriter "head.json" "theirs"]
        putObject ops (IfGenerationMatches generation) (ObjectName "head.json") "mine" >>= (@?= PutPreconditionFailed)
        getObject ops (ObjectName "head.json") >>= \case
          ObjectFound _ bytes -> bytes @?= "theirs"
          other -> assertFailure (show other)
    , testCase "a racing head writer refuses the store's own head replacement" $ do
        (ops, _, faults) <- fakeS3 1000
        store <- newObjectStore ops fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
        initial <- initializeStore store fixtureBinding "client-a" >>= either (assertFailure . show) pure
        writeIORef faults [RacingWriter "head.json" "{\"version\":1}"]
        replaced <- replaceHeadIfGenerationMatches store (Just 0) (initial {headGeneration = 1})
        assertBool "the head another writer replaced is not overwritten" (isLeft replaced)
    , testCase "listings follow continuation tokens and never read a failure as absence" $ do
        (ops, _, faults) <- fakeS3 2
        forM_' [1 .. 5 :: Int] $ \n -> putObject ops IfAbsent (ObjectName ("journal/" <> journalName n)) "e"
        listObjects ops (ObjectName "journal") >>= (@?= Right [ObjectName ("journal/" <> journalName n) | n <- [1 .. 5]])
        getObjects ops (ObjectName "journal") >>= (@?= Right (Map.fromList [(ObjectName ("journal/" <> journalName n), "e") | n <- [1 .. 5]]))
        writeIORef faults [Forbid, Forbid]
        getObject ops (ObjectName "journal/x.json") >>= \case
          GetUnknown _ -> pure ()
          other -> assertFailure ("a refused read was " <> show other)
        listObjects ops (ObjectName "journal") >>= assertBool "a refused listing is an error" . isLeft
    , testCase "the same history stores the same bytes on S3 and on the generation-numbered fake" $ do
        (s3, s3Objects, _) <- fakeS3 1000
        (gcs, gcsObjects) <- fakeObjectState
        forM_' [s3, gcs] $ \ops -> do
          store <- newObjectStore ops fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
          exerciseStore store
        s3Bytes <- Map.fromList . map (\(key, (_, bytes)) -> (T.drop (T.length "inventory/ctx/") key, bytes)) . Map.toList <$> readIORef s3Objects
        gcsBytes <- Map.fromList . map (\(ObjectName key, (_, bytes)) -> (key, bytes)) . Map.toList . snd <$> readIORef gcsObjects
        s3Bytes @?= gcsBytes
    , testCase "a local context selects the object store; a cloud context never does" $ do
        let local = initProfile & #mode .~ Local & #inventoryStore .~ InventoryStoreObject & #inventoryStoreUrl .~ "http://minio.nagare-system.svc.cluster.local:9000/nagare-inventory/local"
        effectiveInventoryStore local @?= InventoryStoreObject
        effectiveInventoryStore (local & #inventoryStore .~ InventoryStoreGcs) @?= InventoryStoreLocal
        fmap (^. #bucket) (objectStoreEndpoint local) @?= Right "nagare-inventory"
        assertBool "cloud" (isLeft (objectStoreEndpoint (local & #mode .~ Cloud)))
        assertBool "no URL" (isLeft (objectStoreEndpoint (local & #inventoryStoreUrl .~ "")))
        assertBool "a public host" (isLeft (objectStoreEndpoint (local & #inventoryStoreUrl .~ "http://store.example.com:9000/b/p")))
        assertBool "no port" (isLeft (objectStoreEndpoint (local & #inventoryStoreUrl .~ "http://minio.nagare-system.svc/b/p")))
        endpoint <- either (assertFailure . T.unpack) pure (objectStoreEndpoint local)
        reachFor True endpoint @?= Right Direct
        reachFor False endpoint @?= Right (ForwardTo "nagare-system" "minio" "9000")
        fmap (`reachFor` endpoint) [] @?= []
        reachFor False (endpoint & #host .~ "127.0.0.1:19000") @?= Right Direct
    , testCase "a bootstrapped context without a stored URL migrates to its object store's inventory bucket" $ do
        let bootstrapped = initProfile & #mode .~ Local & #localObjectStore .~ "http://minio.nagare-system.svc.cluster.local:9000/nagare-backups"
        objectInventoryStoreUrl "mp33" bootstrapped @?= Just "http://minio.nagare-system.svc.cluster.local:9000/nagare-inventory/mp33"
        objectInventoryStoreUrl "mp33" (bootstrapped & #inventoryStoreUrl .~ "http://127.0.0.1:19000/b/p") @?= Just "http://127.0.0.1:19000/b/p"
        objectInventoryStoreUrl "mp33" (bootstrapped & #localObjectStore .~ "") @?= Nothing
        fmap (^. #prefix) (objectStoreEndpoint (bootstrapped & #inventoryStoreUrl .~ fromMaybe "" (objectInventoryStoreUrl "mp33" bootstrapped))) @?= Right "mp33"
    , testCase "credentials come from exactly one private source; a deployer never uses the administrator Secret" $ do
        let none = CredentialSources Nothing Nothing Nothing False
        chooseCredentials none @?= Right FromAdministratorSecret
        assertBool "deployer without credentials" (isLeft (chooseCredentials (none & #deployer .~ True)))
        chooseCredentials (none & #credentialsFile .~ Just "/run/creds.json" & #deployer .~ True) @?= Right (FromFile "/run/creds.json")
        chooseCredentials (none & #environmentKey .~ Just "k" & #environmentSecret .~ Just "s") @?= Right (FromEnvironment (S3Credentials "k" "s"))
        assertBool "file and environment" (isLeft (chooseCredentials (none & #credentialsFile .~ Just "/c" & #environmentKey .~ Just "k" & #environmentSecret .~ Just "s")))
        assertBool "half an environment pair" (isLeft (chooseCredentials (none & #environmentKey .~ Just "k")))
        withSystemTempDirectory "ep251-credentials" $ \directory -> do
          let path = directory </> "credentials.json"
          BS.writeFile path "{\"accessKeyId\":\"deployer\",\"secretAccessKey\":\"s3cr3t\"}"
          setFileMode path 0o644
          refused <- readCredentialFile path
          assertBool "a readable file is refused" (isLeft refused)
          assertBool "the refusal never shows the secret" (either (not . ("s3cr3t" `T.isInfixOf`)) (const False) refused)
          setFileMode path 0o400
          readCredentialFile path >>= (@?= Right (S3Credentials "deployer" "s3cr3t"))
          setFileMode path 0o600 >> BS.writeFile path "{\"accessKeyId\":\"deployer\"}"
          readCredentialFile path >>= assertBool "an incomplete file" . isLeft
    , testCase "the workstation forward opens once, reopens after it exits, and closes with the command" $
        withSystemTempDirectory "ep251-forward" $ \directory -> do
          starts <- newIORef (0 :: Int)
          let pidFile = directory </> "pid"
              spec =
                ForwardSpec
                  { command = do
                      modifyIORef' starts (+ 1)
                      pure (Right ("sh", ["-c", "echo $$ > " <> pidFile <> "; echo 'Forwarding from 127.0.0.1:4242 -> 9000'; exec sleep 60"]))
                  , readyPort = \line -> T.stripSuffix " -> 9000" =<< T.stripPrefix "Forwarding from 127.0.0.1:" line
                  }
          (afterClose, firstPid) <- do
            reach <- forwardedReach spec
            result <- withObjectStoreForwards $ do
              reach >>= (@?= Right ("http://127.0.0.1:4242", "127.0.0.1:4242"))
              reach >>= (@?= Right ("http://127.0.0.1:4242", "127.0.0.1:4242"))
              readIORef starts >>= (@?= 1)
              pid <- T.strip . TE.decodeUtf8 <$> BS.readFile pidFile
              _ <- readProcessWithExitCode "kill" [T.unpack pid] ""
              -- The child is a zombie until the reach reaps it; give the signal time.
              threadDelay 300000
              reach >>= (@?= Right ("http://127.0.0.1:4242", "127.0.0.1:4242"))
              readIORef starts >>= (@?= 2)
              T.strip . TE.decodeUtf8 <$> BS.readFile pidFile
            pure (result, result)
          waitUntilGone afterClose
          alive <- processAlive firstPid
          assertBool "the command's forward is closed when it ends" (not alive)
    , testCase "migration into the object store resumes after an interruption at every request" $ do
        let attempt k = do
              sourceOps <- fakeObjectOps
              (destinationOps, _, faults) <- fakeS3 1000
              source <- newObjectStore sourceOps fixtureBinding "client-a" Nothing >>= either (assertFailure . show) pure
              destination <- newObjectStore destinationOps fixtureBinding "client-b" Nothing >>= either (assertFailure . show) pure
              original <- initializeStore source fixtureBinding "client-a" >>= either (assertFailure . show) pure
              _ <- publishIfAbsent source "objects/sample.json" "sample" >>= either (assertFailure . show) pure
              writeIORef faults (replicate (k - 1) NoFault <> [LoseRequest])
              first'' <- migrateStore source destination "local" "http://minio/inventory/ctx"
              remaining <- length <$> readIORef faults
              writeIORef faults []
              resumed <- either (const (migrateStore source destination "local" "http://minio/inventory/ctx")) (pure . Right) first''
              resumed @?= Right ()
              readHead destination >>= (@?= Right (Just original))
              readObject destination "objects/sample.json" >>= (@?= Right (Just "sample"))
              pure (remaining > 0)
            loop k = attempt k >>= \beyond -> unless beyond (loop (k + 1))
        loop 1
    , testCase "the endpoint names a bucket and a private prefix" $ do
        parseS3Endpoint "http://127.0.0.1:19000/nagare-inventory/local"
          @?= Right (S3Endpoint "http://127.0.0.1:19000" "127.0.0.1:19000" "nagare-inventory" "local")
        assertBool "no prefix" (isLeft (parseS3Endpoint "http://127.0.0.1:19000/nagare-inventory"))
        assertBool "not http" (isLeft (parseS3Endpoint "gs://bucket/prefix"))
        assertBool "dot segments" (isLeft (parseS3Endpoint "http://h/b/../x"))
    , testCase "requests are signed with AWS Signature Version 4 (the published GET Object example)" $ do
        let credentials = S3Credentials "AKIAIOSFODNN7EXAMPLE" "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
            at = UTCTime (fromGregorian 2013 5 24) (secondsToDiffTime 0)
            headers = signedHeaders credentials "us-east-1" at methodGet "examplebucket.s3.amazonaws.com" "/test.txt" [] [("Range", "bytes=0-9")] ""
        lookup "Authorization" headers
          @?= Just "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
        show credentials @?= "S3Credentials \"AKIAIOSFODNN7EXAMPLE\" <secret>"
    ]
  where
    forM_' xs f = mapM_ f xs
    processAlive pid = (\(code, _, _) -> code == ExitSuccess) <$> readProcessWithExitCode "kill" ["-0", T.unpack pid] ""
    waitUntilGone pid = go (100 :: Int)
      where
        go 0 = assertFailure ("process " <> T.unpack pid <> " is still running")
        go n = processAlive pid >>= \alive -> when alive (threadDelay 50000 >> go (n - 1))
    journalName n = T.pack (replicate (20 - length (show n)) '0' <> show n) <> ".json"

data Fault = NoFault | LoseAcknowledgement | LoseRequest | RacingWriter !Text !ByteString | Forbid

-- | An S3 server holding @bucket/key -> (etag, bytes)@: conditional PUT,
-- GET with ETag, and ListObjectsV2 paged at @page@ keys.
fakeS3 :: Int -> IO (ObjectOps, IORef (Map.Map Text (Text, ByteString)), IORef [Fault])
fakeS3 page = do
  objects <- newIORef Map.empty
  counter <- newIORef (0 :: Int)
  faults <- newIORef []
  let endpoint = S3Endpoint "http://fake" "fake" "inventory" "ctx"
      nextEtag = atomicModifyIORef' counter (\n -> (n + 1, "\"etag-" <> T.pack (show (n + 1)) <> "\""))
      noSuchKey = S3Response 404 [] "<Error><Code>NoSuchKey</Code></Error>"
      store key bytes = do
        etag <- nextEtag
        modifyIORef' objects (Map.insert key (etag, bytes))
        pure etag
      handle method path query extra payload
        | method == methodPut = do
            let key = T.drop 1 path
            current <- Map.lookup key <$> readIORef objects
            case (lookup "If-None-Match" extra, lookup "If-Match" extra, current) of
              (Just "*", _, Just _) -> pure (S3Response 412 [] "")
              (_, Just _, Nothing) -> pure noSuchKey
              (_, Just expected, Just (etag, _)) | TE.encodeUtf8 etag /= expected -> pure (S3Response 412 [] "")
              _ -> do
                etag <- store key payload
                pure (S3Response 200 [("etag", TE.encodeUtf8 etag)] "")
        | method == methodGet
        , Just prefix <- lookup "prefix" query = do
            keys <- filter (prefix `T.isPrefixOf`) . map (T.drop (T.length "inventory/")) . Map.keys <$> readIORef objects
            let start = maybe 0 (read . T.unpack) (lookup "continuation-token" query)
                selected = take page (drop start keys)
                more = start + page < length keys
            pure
              ( S3Response
                  200
                  []
                  ( "<ListBucketResult>"
                      <> BS.concat ["<Contents><Key>" <> TE.encodeUtf8 key <> "</Key></Contents>" | key <- selected]
                      <> "<IsTruncated>"
                      <> (if more then "true" else "false")
                      <> "</IsTruncated>"
                      <> (if more then "<NextContinuationToken>" <> BC.pack (show (start + page)) <> "</NextContinuationToken>" else "")
                      <> "</ListBucketResult>"
                  )
              )
        | method == methodGet = do
            current <- Map.lookup (T.drop 1 path) <$> readIORef objects
            pure (maybe noSuchKey (\(etag, bytes) -> S3Response 200 [("etag", TE.encodeUtf8 etag)] bytes) current)
        | otherwise = pure (S3Response 405 [] "")
      transport method path query extra payload = do
        fault <- atomicModifyIORef' faults (\case [] -> ([], Nothing); f : rest -> (rest, Just f))
        case fault of
          Nothing -> Right <$> handle method path query extra payload
          Just NoFault -> Right <$> handle method path query extra payload
          Just Forbid -> pure (Right (S3Response 403 [] "<Error><Code>AccessDenied</Code></Error>"))
          Just LoseRequest -> pure (Left "connection refused")
          Just LoseAcknowledgement -> handle method path query extra payload >> pure (Left "connection reset after the request was sent")
          Just (RacingWriter key bytes) -> store ("inventory/ctx/" <> key) bytes >> Right <$> handle method path query extra payload
  pure (s3ObjectOpsWith transport endpoint, objects, faults)
