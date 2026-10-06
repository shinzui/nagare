-- | The in-memory object store under the inventory store in tests: generation
-- conditions as a bucket checks them, and no other behaviour. EP-179 exposes
-- its whole state, so the recovery model can snapshot and restore a run.
module Nagare.Test.World.ObjectStore
  ( FakeObjects
  , fakeObjectOps
  , fakeObjectState
  )
where

import Control.Concurrent (threadDelay)
import Data.ByteString (ByteString)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Store.ObjectOps

-- | The last generation issued, and every object with its generation.
type FakeObjects = (Integer, Map.Map ObjectName (Generation, ByteString))

fakeObjectOps :: IO ObjectOps
fakeObjectOps = fst <$> fakeObjectState

-- | The store and the reference that holds its state.
fakeObjectState :: IO (ObjectOps, IORef FakeObjects)
fakeObjectState = do
  state <- newIORef (0, Map.empty)
  pure . (,state) $
    ObjectOps
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
           in if matches
                then
                  let next = lastGeneration + 1
                      generation = Generation next
                   in ((next, Map.insert name (generation, bytes) objects), PutWritten generation)
                else ((lastGeneration, objects), PutPreconditionFailed)
      , listObjects = \(ObjectName prefix) -> do
          (_, objects) <- readIORef state
          pure
            ( Right
                [ name
                | name@(ObjectName value) <- Map.keys objects
                , prefix `T.isPrefixOf` value
                ]
            )
      , pauseBeforeRetry = threadDelay
      }
