-- | Filesystem access for the inventory store: durable writes (a private
-- temporary file renamed into place, file and directory synchronised) and
-- reads that accept only private regular files.
module Nagare.Inventory.Store.FileIO
  ( atomicWrite
  , readPrivateFile
  , syncDirectory
  , syncFile
  )
where

import Control.Exception (IOException, bracket, catch, try)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Nagare.Dsl.Prelude
import System.Directory (createDirectoryIfMissing, pathIsSymbolicLink, removeFile, renameFile)
import System.FilePath (takeDirectory)
import System.IO (hClose, hFlush, openBinaryTempFile)
import System.Posix.Files (fileMode, getFileStatus, isRegularFile, setFileMode)
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

-- | Read a regular, non-symlinked file that no group or other user can access.
readPrivateFile :: FilePath -> IO (Either IOException ByteString)
readPrivateFile path = try $ do
  linked <- pathIsSymbolicLink path
  when linked (ioError (userError "file is a symlink"))
  status <- getFileStatus path
  unless (isRegularFile status) (ioError (userError "path is not a regular file"))
  unless (fileMode status .&. 0o077 == 0) (ioError (userError "file is accessible by group or other users"))
  BS.readFile path
