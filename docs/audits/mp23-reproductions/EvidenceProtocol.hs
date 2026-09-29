-- Offline protocol experiment. No provider adapter execution or production edits.
module Main where
import Prelude
import Control.Concurrent
import Control.Exception (SomeException, try, throwIO)
import Control.Monad
import Data.Aeson (toJSON, eitherDecodeStrict')
import Data.ByteString qualified as BS
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Control.Lens ((^.))
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Inventory.Store.ObjectOps
import Nagare.Inventory.Digest
import Nagare.Resource.Inventory
import Nagare.Resource.Wire (canonicalValue)
import OperationalHelpers (fakeObjectOps, ok)
import NativeHelpers qualified as N
import System.Environment (getEnv)

must action = action >>= either (ioError . userError . show) pure

checkedIndex ops store bundle = do
  let context = reviewContextBinding (reviewBundleDocument bundle)
  forM_ (Map.elems (N.members bundle)) $ \(member,_) -> do
    outcome <- putObject ops IfAbsent (N.lookupName context member)
      (ok (canonicalValue (toJSON (reviewDigest bundle))))
    case outcome of
      PutNoEffect reason -> ioError (userError (T.unpack reason))
      _ -> pure () -- Written, precondition conflict, or unknown: verify actual witness.
    void (must (N.selectedWith True ops store context [member]))
publish ops store bundle = do
  void (must (publishReview store bundle))
  checkedIndex ops store bundle

newStore ops = must (newObjectStore ops N.binding "protocol" Nothing)
assert = N.assert
main = do
  templateOps <- fakeObjectOps
  templateStore <- newStore templateOps
  void (must (initializeStore templateStore N.binding "protocol"))
  bundle <- N.prepare templateStore ("current" :: T.Text) 0
  let wanted = map fst (Map.elems (N.members bundle))
  -- Six write boundaries: scope, two native members, review, two lookup entries.
  forM_ ["before","after"] $ \phase -> forM_ [1..6] $ \cut -> do
    base <- fakeObjectOps
    plain <- newStore base
    void (must (initializeStore plain N.binding "protocol"))
    before <- must (readHead plain)
    writes <- newIORef (0 :: Int)
    fired <- newIORef False
    let injected = base {putObject = \condition key bytes -> do
          n <- atomicModifyIORef' writes (\n -> (n+1,n+1))
          if n /= cut then putObject base condition key bytes else do
            writeIORef fired True
            if phase == "before" then pure (PutNoEffect "injected before write")
            else putObject base condition key bytes >> pure (PutUnknown "injected lost acknowledgement")}
    faultStore <- newStore injected
    first <- try (publish injected faultStore bundle) :: IO (Either SomeException ())
    didFire <- readIORef fired
    assert "fault reached" didFire
    after <- must (readHead plain)
    assert "publication cannot admit or advance head" (after == before)
    publish base plain bundle
    void (must (N.selectedWith True base plain N.binding wanted))
    print ("write-fault",phase,cut,"first",either (const "refused") (const "verified") first,"retry verified; head unchanged")
  -- Two distinct immutable reviews can be valid witnesses for the same binding.
  base <- fakeObjectOps
  store <- newStore base
  void (must (initializeStore store N.binding "protocol"))
  let other = ReviewBundle ((reviewBundleDocument bundle) {reviewPayloadIdentity="equivalent-publisher"})
        (reviewBundleScopes bundle) (reviewBundleNative bundle)
      firstMember = fst (snd (Map.findMin (N.members bundle)))
      contested = N.lookupName N.binding firstMember
  arrived <- newChan
  release <- newEmptyMVar
  let concurrent = base {putObject = \condition key bytes -> do
        when (key == contested) (writeChan arrived () >> readMVar release)
        putObject base condition key bytes}
  results <- replicateM 2 newEmptyMVar
  forM_ (zip results [bundle,other]) $ \(result,b) -> void (forkIO
    ((try (publish concurrent store b) :: IO (Either SomeException ())) >>= putMVar result))
  readChan arrived; readChan arrived; putMVar release ()
  outcomes <- traverse takeMVar results
  assert "both equivalent publishers validate winner" (all (either (const False) (const True)) outcomes)
  void (must (N.selectedWith True base store N.binding wanted))
  print ("concurrent equivalent publishers","both verified one valid conditional-write winner")
  -- Corrupt an existing winner; publication must not replace or trust it.
  observed <- getObject base contested
  gen <- case observed of ObjectFound g _ -> pure g; _ -> error "no winner"
  void (putObject base (IfGenerationMatches gen) contested "{}")
  rejected <- try (publish base store bundle) :: IO (Either SomeException ())
  assert "corrupt winner refused" (either (const True) (const False) rejected)
  unchanged <- getObject base contested
  assert "corrupt winner not overwritten" (case unchanged of ObjectFound _ b -> b == "{}"; _ -> False)
  print ("corrupt conditional-write winner","refused without overwrite")
  -- Unknown reads must not become absent/success.
  let unreadable = base {getObject = \key -> if key == contested then pure (GetUnknown "injected read failure") else getObject base key}
  uncertain <- try (checkedIndex unreadable store bundle) :: IO (Either SomeException ())
  assert "unknown witness read refused" (either (const True) (const False) uncertain)
  print ("unknown lookup read","refused")
  rebuildExperiment bundle wanted

-- Persistent checkpoint: original head, captured immutable review list, cursor.
-- A budget exhaustion is explicitly incomplete, never empty evidence/success.
rebuildStep ops store checkpoint budget interrupt = do
  exists <- try (BS.readFile checkpoint) :: IO (Either SomeException BS.ByteString)
  state <- case exists of
    Right bytes -> pure (ok (eitherDecodeStrict' bytes))
    Left _ -> do
      snapshot <- must (readStoreSnapshot store)
      pure (storeSnapshotHead snapshot, Set.toAscList (storeSnapshotReviewDigests snapshot), 0 :: Int)
  let (captured, digests, cursor) = state
      save n = BS.writeFile checkpoint (ok (canonicalValue (toJSON (captured,digests,n))))
  current <- must (readHead store)
  assert "rebuild captured head still current" (current == Just captured)
  save cursor
  let batch = take budget (drop cursor digests)
  forM_ (zip [cursor+1..] batch) $ \(next,digest) -> do
    bundle <- must (loadPublishedReview store digest)
    checkedIndex ops store bundle
    when interrupt (ioError (userError "injected interruption before cursor commit"))
    save next
  final <- must (readHead store)
  assert "rebuild final head still current" (final == Just captured)
  pure (cursor + length batch == length digests, cursor + length batch, length digests)

rebuildExperiment bundle wanted = do
  root <- getEnv "MP23_PROTOCOL_ROOT"
  sourceOps <- fakeObjectOps
  source <- newStore sourceOps
  initial <- must (initializeStore source N.binding "protocol")
  void (must (publishReview source bundle))
  -- Synthetic accepted catalogue for the same immutable scopes; no provider effect.
  must (replaceHeadIfGenerationMatches source (Just (headGeneration initial)) initial
    {headGeneration=headGeneration initial+1,headAccepted=reviewDesiredRevisions (reviewBundleDocument bundle)})
  forM_ [1..3] $ \n -> do
    let doc = (reviewBundleDocument bundle) {reviewPayloadIdentity=T.pack (show n)}
    void (must (publishReview source (ReviewBundle doc (reviewBundleScopes bundle) (reviewBundleNative bundle))))
  locked <- withProcessLock source (\l -> exportStore l (root <> "/old-history-export"))
  void (pure (ok (ok locked)))
  restoredOps <- fakeObjectOps
  -- Match the supported command: restore to a fresh local root, then migrate
  -- if desired. Object-store construction installs format.json and is not an
  -- empty restore destination. Derived sidecars are isolated recording objects.
  restored <- must (openFilesystemStore (root <> "/restored"))
  must (restoreStoreFor restored (root <> "/old-history-export") N.binding)
  originalHead <- must (readHead source)
  restoredHead <- must (readHead restored)
  assert "real export/restore preserves head" (originalHead == restoredHead)
  missing <- N.selectedWith True restoredOps restored N.binding wanted
  assert "old restored history lacks lookup" (either (const True) (const False) missing)
  interrupted <- try (rebuildStep restoredOps restored (root <> "/cursor.json") 1 True) :: IO (Either SomeException (Bool,Int,Int))
  assert "interruption reached" (either (const True) (const False) interrupted)
  first <- rebuildStep restoredOps restored (root <> "/cursor.json") 1 False
  assert "bounded progress incomplete" (first == (False,1,4))
  rest <- replicateM 3 $ do
    reopened <- must (openFilesystemStore (root <> "/restored"))
    rebuildStep restoredOps reopened (root <> "/cursor.json") 1 False
  assert "persistent cursor completes" (last rest == (True,4,4))
  void (must (N.selectedWith True restoredOps restored N.binding wanted))
  print ("restored old history",first,rest,"interrupted entry repeated safely; exact selected bytes available")
  -- A changed head invalidates completion for the captured accepted catalogue.
  now <- must (readHead restored) >>= maybe (error "head absent") pure
  must (replaceHeadIfGenerationMatches restored (Just (headGeneration now)) now {headGeneration=headGeneration now+1})
  stale <- try (rebuildStep restoredOps restored (root <> "/cursor.json") 1 False) :: IO (Either SomeException (Bool,Int,Int))
  assert "head change invalidates checkpoint" (either (const True) (const False) stale)
  print ("head changed during rebuild","stale checkpoint refused; no false completion")
  fresh <- rebuildStep restoredOps restored (root <> "/fresh-cursor.json") 4 False
  assert "explicit fresh snapshot succeeds" (fresh == (True,4,4))
  print ("explicit rebuild restart",fresh)
