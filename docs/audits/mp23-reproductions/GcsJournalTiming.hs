{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- Read-only timing of the production factory and complete journal download.
module Main (main) where

import Data.Aeson (encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy.Char8 qualified as LBS
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (diffUTCTime, getCurrentTime)
import Nagare.Inventory.Store.ObjectOps
import Nagare.Inventory.Store.Remote (remoteObjectOps)
import System.Environment (getArgs)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [project, url] -> do
      start <- getCurrentTime
      ops <- remoteObjectOps (T.pack project) (T.pack url) >>= either (const (fail "store initialization refused")) pure
      ready <- getCurrentTime
      values <- getObjects ops (ObjectName "journal") >>= either (const (fail "journal download refused")) pure
      done <- getCurrentTime
      LBS.putStrLn $
        encode $
          object
            [ "setupSeconds" .= (realToFrac (diffUTCTime ready start) :: Double)
            , "journalSeconds" .= (realToFrac (diffUTCTime done ready) :: Double)
            , "objects" .= Map.size values
            , "bytes" .= sum (map BS.length (Map.elems values))
            ]
    _ -> fail "usage: gcs-journal-timing PROJECT STORE_URL"
