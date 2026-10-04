-- | Durable filesystem writes for the inventory store: a private temporary file
-- renamed into place, with the file and its directory synchronised.
module Nagare.Inventory.Store.FileIO
  ( atomicWrite
  , syncDirectory
  , syncFile
  )
where

import Control.Exception (IOException, bracket, catch)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Nagare.Dsl.Prelude
import System.Directory (createDirectoryIfMissing, removeFile, renameFile)
import System.FilePath (takeDirectory)
import System.IO (hClose, hFlush, openBinaryTempFile)
import System.Posix.Files (setFileMode)
import System.Posix.IO (OpenMode (ReadOnly), closeFd, defaultFileFlags, openFd)
import System.Posix.Unistd (fileSynchronise)

atomicWrite :: FilePath -> ByteString -> IO ()
atomicWrite path bytes = do
  let parent = takeDirectory path
  createDirectoryIfMissing True parent
  setFileMode parent 0o700
  (temporary, handle) <- openBinaryTempFile parent ".inventory-object.tmp"
  let cleanup = do
        hClose handle `catch` (\(_ :: IOException) -> pure ())
        removeFile temporary `catch` (\(_ :: IOException) -> pure ())
  ( do
      setFileMode temporary 0o600
      BS.hPut handle bytes
      hFlush handle
      hClose handle
      syncFile temporary
      renameFile temporary path
      setFileMode path 0o600
      syncDirectory parent
    )
    `catch` \(err :: IOException) -> cleanup >> ioError err

syncFile :: FilePath -> IO ()
syncFile path = bracket (openFd path ReadOnly defaultFileFlags) closeFd fileSynchronise

syncDirectory :: FilePath -> IO ()
syncDirectory path = bracket (openFd path ReadOnly defaultFileFlags) closeFd fileSynchronise
