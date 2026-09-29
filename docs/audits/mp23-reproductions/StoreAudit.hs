module Main where
import Prelude
import Control.Monad
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.ByteString qualified as BS
import Data.Either (isRight)
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
  forM_ [50,500] $ \n -> do
    base <- fakeObjectOps
    reads <- newIORef (0 :: Int)
    batches <- newIORef (0 :: Int)
    let ops = base { getObject = \name -> modifyIORef' reads (+1) >> getObject base name,
                     getObjects = \name -> modifyIORef' batches (+1) >> getObjects base name }
    store <- must (newObjectStore ops binding "audit" Nothing)
    headValue <- must (initializeStore store binding "audit")
    let make prior i = JournalEvent 1 i prior tx Nothing Pending "audit" "audit"
        events = snd (foldl (\(prior,es) i -> let e = make prior i in (Just (journalEventDigest e),es ++ [e])) (Nothing,[]) [0..n-1])
    forM_ events $ \e -> void (must (appendAtSequence store (eventSequence e) (encodeJournalEvent e)))
    let active = headValue {headGeneration=1, headSequence=n, headActiveTransaction=Just "tx-audit"}
    void (must (replaceHeadIfGenerationMatches store (Just 0) active))
    writeIORef reads 0
    writeIORef batches 0
    status <- loadActiveTransactionStatus store active
    r <- readIORef reads
    b <- readIORef batches
    print ("active status", n, isRight status, r, b)
    writeIORef reads 0
    writeIORef batches 0
    void (must (readJournalPrefix store n))
    r2 <- readIORef reads
    b2 <- readIORef batches
    print ("batch prefix",n,r2,b2)
  baseWrite <- fakeObjectOps
  calls <- newIORef ([] :: [String])
  let writeOps = baseWrite
        { getObject = \name -> do
            result <- getObject baseWrite name
            modifyIORef' calls (("get " ++ show name ++ if result == ObjectAbsent then " absent" else " found") :)
            pure result
        , putObject = \condition name bytes -> do
            modifyIORef' calls (("put " ++ show name):)
            putObject baseWrite condition name bytes }
  writeStore <- must (newObjectStore writeOps binding "audit" Nothing)
  initial <- must (initializeStore writeStore binding "audit")
  let claimed = initial {headGeneration=1, headActiveTransaction=Just "tx-audit", headExecutorClaim=Just (ExecutorClaim "tx-audit" "audit" 1 "audit")}
  void (must (replaceHeadIfGenerationMatches writeStore (Just 0) claimed))
  result <- withProcessLock writeStore $ \locked -> forM_ [0,1] $ \i -> do
    writeIORef calls []
    void (must (E.appendEvent locked tx Nothing Pending (T.pack (show i))))
    recorded <- reverse <$> readIORef calls
    print ("append event",i,recorded)
  print (fmap (const "append calls recorded") result)
  base <- fakeObjectOps
  reads <- newIORef ([] :: [ObjectName])
  let ops = base {getObject = \name -> modifyIORef' reads (name:) >> getObject base name}
  store <- must (newObjectStore ops binding "audit" Nothing)
  void (must (initializeStore store binding "audit"))
  history <- must (loadInventoryHistory store)
  let inventory = ok (mkScopeSnapshot binding Map.empty Map.empty >>= composeSnapshot)
  before <- loadAcceptedNative store history inventory
  print ("empty native before unrelated review",isRight before)
  let unrelated = "{}"
  void (must (publishIfAbsent store (reviewKey (contentDigest unrelated)) unrelated))
  after <- loadAcceptedNative store history inventory
  print ("empty native after unrelated malformed review",fmap (const ()) after)

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
