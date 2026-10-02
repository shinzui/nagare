{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where
import Control.Lens ((^.))
import Control.Monad (unless)
import Data.Aeson (Value, eitherDecodeStrict', encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as LBS
import Data.Aeson.Types (Pair)
import Data.IORef
import Data.Text qualified as T
import GHC.Clock (getMonotonicTimeNSec)
import Nagare.Cli.Inventory.Execution (inventoryExecutionRegistry)
import Nagare.Inventory.Execute qualified as E
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Inventory.Store.ObjectOps
import Nagare.Inventory.Store.Remote (remoteObjectOps)
import Nagare.Resource.Types
import System.Environment (getArgs)
must :: Show e => IO (Either e a) -> IO a
must action = action >>= either (fail . show) pure
main :: IO ()
main = do
  [directory,url,cache,traceFile] <- getArgs
  public <- must (loadReviewBundle directory)
  let binding=reviewContextBinding (reviewBundleDocument public)
  unless (nameText (binding ^. #project)=="tan-ng-labs" && T.pack url=="gs://tan-ng-labs-ep150-pmkjjpp-state/inventory") (fail "wrong bounded fixture")
  phase <- newIORef ("remote-setup" :: T.Text)
  stages <- newIORef ([] :: [Value])
  let seconds a b=fromIntegral (b-a)/1e9 :: Double
      stage :: T.Text -> IO a -> IO a
      stage label action = do
        writeIORef phase label
        start <- getMonotonicTimeNSec
        value <- action
        end <- getMonotonicTimeNSec
        modifyIORef' stages (object ["stage" .= label,"seconds" .= seconds start end]:)
        pure value
  raw <- stage "remote-setup" (must (remoteObjectOps (nameText (binding ^. #project)) (T.pack url)))
  let timed :: T.Text -> ObjectName -> (a -> [Pair]) -> IO a -> IO a
      timed method (ObjectName key) extra action = do
        label <- readIORef phase
        start <- getMonotonicTimeNSec
        value <- action
        end <- getMonotonicTimeNSec
        LBS.appendFile traceFile (encode (object (["phase" .= label,"method" .= (method :: T.Text),"key" .= key,"seconds" .= seconds start end]<>extra value))<>"\n")
        pure value
      ops=raw
        { getObject= \key -> timed "get" key (const []) (getObject raw key)
        , getObjects= \key -> timed "batch" key (const []) (getObjects raw key)
        , listObjects= \key -> timed "list" key (const []) (listObjects raw key)
        , putObject= \condition key@(ObjectName name) bytes -> do
            unless (name=="head.json" || "journal/" `T.isPrefixOf` name) (fail "unexpected publication")
            timed "put" key (\outcome -> ["condition" .= show condition,"outcome" .= show outcome,"publication" .= (either (error . show) id (eitherDecodeStrict' bytes) :: Value)]) (putObject raw condition key bytes)
        }
  store <- stage "open-store" (must (openObjectStoreReadOnly ops binding "mp23-independent-native-timing" (Just cache)))
  bundle <- stage "load-published-review" (must (loadPublishedReview store (reviewDigest public)))
  unless (reviewBundleDocument bundle==reviewBundleDocument public && reviewBundleScopes bundle==reviewBundleScopes public) (fail "saved review differs from published authority")
  registry <- stage "registry-construction" (inventoryExecutionRegistry (Just "ep150-preview") store bundle)
  snapshot <- stage "read-review-snapshot" (must (readReviewSnapshot store (reviewDigest bundle)))
  reviewed <- either (fail . show) pure (verifyReview snapshot bundle)
  result <- stage "apply-reviewed" (must (E.applyReviewed store registry reviewed))
  case result of E.Converged _ -> pure (); _ -> fail (show result)
  final <- stage "read-final-head" (must (readHead store) >>= maybe (fail "missing head") pure)
  unless (headActiveTransaction final==Nothing && headExecutorClaim final==Nothing && headAccepted final==headConverged final) (fail "not terminal")
  rows <- reverse <$> readIORef stages
  LBS.putStrLn (encode (object ["result" .= show result,"stages" .= rows,"finalHead" .= final]))
