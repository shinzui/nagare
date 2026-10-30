-- | The identity of a written static build context.
--
-- A content digest is the SHA-256 over every directory and file of a context:
-- sorted relative paths, regular-versus-executable mode and bytes. It names what
-- the operator asked to serve, independently of how Docker packages it (an OCI
-- manifest digest carries a creation time, so identical input yields different
-- manifests). The same tree digests identically on every machine; one changed
-- byte, name or mode changes it.
module Nagare.Static.ContentDigest
  ( ContentDigest (..)
  , contentDigestText
  , digestContextTree
  )
where

import Crypto.Hash (Context, Digest, SHA256, hashFinalize, hashInit, hashUpdate)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding (Context)
import System.Directory (listDirectory)
import System.FilePath ((</>))
import System.Posix.Files
  ( fileMode
  , getFileStatus
  , isDirectory
  , isRegularFile
  , ownerExecuteMode
  )

newtype ContentDigest = ContentDigest Text
  deriving stock (Eq, Ord, Show)

-- | @sha256:<hex>@.
contentDigestText :: ContentDigest -> Text
contentDigestText (ContentDigest t) = t

-- | Digest the tree rooted at @root@. Entries are visited in sorted order and
-- framed with lengths, so no two distinct trees share a byte stream. Only
-- directories and regular files are expected; the writer refuses anything else
-- before a tree reaches this function.
digestContextTree :: FilePath -> IO ContentDigest
digestContextTree root = do
  context <- walk (hashInit :: Context SHA256) ""
  pure (ContentDigest ("sha256:" <> T.pack (show (hashFinalize context :: Digest SHA256))))
  where
    walk context relative = do
      names <- sort <$> listDirectory (root </> relative)
      foldlM' context names $ \acc name -> do
        let rel = if null relative then name else relative </> name
            path = root </> rel
        status <- getFileStatus path
        if isDirectory status
          then walk (frame acc 'd' rel BS.empty) rel
          else
            if isRegularFile status
              then do
                bytes <- BS.readFile path
                let tag = if fileMode status .&. ownerExecuteMode /= 0 then 'x' else 'f'
                pure (frame acc tag rel bytes)
              else ioError (userError ("not a regular file or directory: " <> path))

    foldlM' acc [] _ = pure acc
    foldlM' acc (x : xs) step = step acc x >>= \next -> foldlM' next xs step

    frame :: Context SHA256 -> Char -> FilePath -> ByteString -> Context SHA256
    frame context tag rel bytes =
      let pathBytes = TE.encodeUtf8 (T.pack rel)
       in hashUpdate context (BC.singleton tag <> lengthPrefix pathBytes <> lengthPrefix bytes)

    lengthPrefix bytes = BC.pack (show (BS.length bytes) <> ":") <> bytes
