-- Diagnostic only: exercise current production code; no provider credentials.
module Main where

import Prelude
import Control.Monad
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.ByteString.Char8 qualified as BS
import System.Environment
import System.Directory (createDirectoryIfMissing)
import Nagare.Inventory.Store
import Nagare.Inventory.Store.ObjectOps
import Nagare.Inventory.Status
import Nagare.Inventory.Plan
import Nagare.Inventory.Journal
import Nagare.Inventory.Execute qualified as E
import Nagare.Inventory.Digest
import Nagare.Resource.Inventory
import Nagare.Resource.Types

ok :: Show e => Either e a -> a
ok = either (error . show) id
must :: Show e => IO (Either e a) -> IO a
must action = ok <$> action
binding = ContextBinding (ok (mkContextId "audit")) (ok (mkName "project"))
tx = ok (mkTransactionId "tx-audit")

main = do
  args <- getArgs
  case args of
    [mode] | mode `elem` ["transport", "snapshot"] -> do
      let base = ok (gcloudObjectOps "gs://audit.invalid/private")
      headMemo <- newIORef Nothing
      -- Counterfactual only: reuse one observed head within one append. The
      -- underlying transport still performs the real generation-conditional PUT.
      let ops = if mode == "transport" then base else base
            { getObject = \name -> if name /= ObjectName "head.json" then getObject base name else do
                cached <- readIORef headMemo
                case cached of
                  Just value -> pure value
                  Nothing -> do
                    value <- getObject base name
                    writeIORef headMemo (Just value)
                    pure value
            , putObject = \condition name bytes -> do
                outcome <- putObject base condition name bytes
                when (name == ObjectName "head.json") (writeIORef headMemo Nothing)
                pure outcome }
      store <- must (newObjectStore ops binding "audit" Nothing)
      initial <- must (initializeStore store binding "audit")
      let claimed = initial {headGeneration=1, headActiveTransaction=Just "tx-audit", headExecutorClaim=Just (ExecutorClaim "tx-audit" "audit" 1 "audit")}
      void (must (replaceHeadIfGenerationMatches store (Just 0) claimed))
      logPath <- getEnv "MP23_CALLS"
      result <- withProcessLock store $ \locked -> forM_ [0,1] $ \i -> do
        writeIORef headMemo Nothing
        BS.writeFile logPath ""
        void (must (E.appendEvent locked tx Nothing Pending (T.pack (show i))))
        calls <- BS.lines <$> BS.readFile logPath
        print ("transport-append", i, length calls)
        mapM_ BS.putStrLn calls
      print (fmap (const "ok") result)
      writeIORef headMemo Nothing
      setEnv "MP23_RACE_HEAD" "1"
      raced <- withProcessLock store $ \locked -> E.appendEvent locked tx Nothing Pending "race"
      print ("concurrent-head-replacement", raced)
    _ -> do
      forM_ [(cached,n) | cached <- [False,True], n <- [0,50,500]] $ \(cached,n) -> do
        base <- fakeObjectOps
        reads <- newIORef (0 :: Int)
        lists <- newIORef (0 :: Int)
        let ops = base
              { getObject = \name -> modifyIORef' reads (+1) >> getObject base name
              , listObjects = \name -> modifyIORef' lists (+1) >> listObjects base name }
        cacheRoot <- getEnv "MP23_CACHE"
        let cachePath = cacheRoot <> "/" <> show n
        when cached (createDirectoryIfMissing True cachePath)
        store <- must (newObjectStore ops binding "audit" (if cached then Just cachePath else Nothing))
        void (must (initializeStore store binding "audit"))
        -- Valid canonical unpublished-operation reviews, unrelated to the empty
        -- accepted inventory. Nothing has been admitted by these documents.
        forM_ [1..n] $ \i -> do
          let document = ReviewDocument 1 binding i 0 Map.empty Map.empty
                (contentDigest "empty") "audit" "1" [] [] Map.empty Map.empty Map.empty
              bytes = encodeReviewDocument document
          void (must (publishIfAbsent store (reviewKey (contentDigest bytes)) bytes))
        history <- must (loadInventoryHistory store)
        let inventory = ok (mkScopeSnapshot binding Map.empty Map.empty >>= composeSnapshot)
        forM_ ["first", "repeat"] $ \label -> do
          writeIORef reads 0
          writeIORef lists 0
          native <- must (loadAcceptedNative store history inventory)
          r <- readIORef reads
          l <- readIORef lists
          print ("native-history", cached, n, label, r, l, Map.size (fst native), Map.size (snd native))
      base <- fakeObjectOps
      store <- must (newObjectStore base binding "audit" Nothing)
      void (must (initializeStore store binding "audit"))
      history <- must (loadInventoryHistory store)
      let inventory = ok (mkScopeSnapshot binding Map.empty Map.empty >>= composeSnapshot)
      void (must (publishIfAbsent store (reviewKey (contentDigest "{}")) "{}"))
      result <- loadAcceptedNative store history inventory
      print ("unrelated-malformed-review", fmap (const ()) result)

fakeObjectOps :: IO ObjectOps
fakeObjectOps = do
  state <- newIORef (0 :: Integer, Map.empty)
  pure ObjectOps
    { getObject = \name -> do
        (_, objects) <- readIORef state
        pure $ maybe ObjectAbsent (uncurry ObjectFound) (Map.lookup name objects)
    , getObjects = \(ObjectName prefix) -> do
        (_, objects) <- readIORef state
        pure (Right (Map.map snd (Map.filterWithKey (\(ObjectName name) _ -> (prefix <> "/") `T.isPrefixOf` name) objects)))
    , putObject = \condition name bytes -> atomicModifyIORef' state $ \(lastGeneration, objects) ->
        let existing = Map.lookup name objects
            matches = case condition of
              IfAbsent -> maybe True (const False) existing
              IfGenerationMatches expected -> maybe False ((== expected) . fst) existing
         in if matches then
              let next = lastGeneration + 1
                  generation = Generation next
               in ((next, Map.insert name (generation, bytes) objects), PutWritten generation)
            else ((lastGeneration, objects), PutPreconditionFailed)
    , listObjects = \(ObjectName prefix) -> do
        (_, objects) <- readIORef state
        pure (Right [name | name@(ObjectName value) <- Map.keys objects,
                     prefix `T.isPrefixOf` value])
    }
