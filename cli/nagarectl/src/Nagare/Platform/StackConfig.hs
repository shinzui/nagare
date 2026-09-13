{-# LANGUAGE OverloadedStrings #-}

-- | The context-owned Pulumi stack configuration (EP-121).
--
-- @Pulumi.<context>.yaml@ is mutable operator state: it carries the boot image
-- link, the stack encryption salt, and the recorded VM shape. Payload workspaces
-- are immutable per-digest copies that exclude it, so the file lives at one
-- context-owned path under XDG config and every Pulumi working directory links to
-- it. Pulumi writes through the link (verified for @config set@, @--secret@, and
-- @config rm@), but treats a dangling link as empty configuration, so a dangling
-- canonical link is refused here rather than silently read as nothing.
module Nagare.Platform.StackConfig
  ( CanonicalObservation (..)
  , EntryObservation (..)
  , StackLinkAction (..)
  , contextStackConfigPath
  , stackConfigEntryPath
  , planStackLink
  , linkContextStackConfig
  )
where

import Control.Exception (IOException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Target (ContextName, contextNameText, nagareConfigDir)
import System.Directory
  ( canonicalizePath
  , copyFile
  , createDirectoryIfMissing
  , createFileLink
  , doesFileExist
  , getSymbolicLinkTarget
  , pathIsSymbolicLink
  , removeFile
  , renamePath
  )
import System.FilePath (takeDirectory, (</>))

-- | What is at the canonical path.
data CanonicalObservation
  = CanonicalAbsent
  | CanonicalPresent !ByteString
  | -- | A symlink whose target does not exist, typically an unwired private repository.
    CanonicalDangling !FilePath
  deriving stock (Eq, Show)

-- | What is at @<pulumiDir>/Pulumi.<context>.yaml@.
data EntryObservation
  = EntryAbsent
  | -- | A symlink, with its raw target and whether it resolves to the same real
    -- file as the canonical path.
    EntryLinksTo !FilePath !Bool
  | EntryRegular !ByteString
  deriving stock (Eq, Show)

data StackLinkAction
  = -- | The entry already reads the canonical file.
    AlreadyLinked
  | -- | Create the link where nothing exists.
    LinkOnly
  | -- | Replace an identical regular file with the link.
    ReplaceWithLink
  | -- | Copy a pre-0.2.1 workspace file to the canonical path, then link it.
    AdoptThenLink
  | -- | Create an empty canonical file (valid Pulumi stack config), then link it.
    CreateEmptyThenLink
  | RefuseStackLink !Text
  deriving stock (Eq, Show)

contextStackConfigPath :: ContextName -> IO FilePath
contextStackConfigPath name = do
  root <- nagareConfigDir
  pure (root </> "pulumi" </> stackFileName name)

stackConfigEntryPath :: ContextName -> FilePath -> FilePath
stackConfigEntryPath name pulumiDir = pulumiDir </> stackFileName name

stackFileName :: ContextName -> FilePath
stackFileName name = "Pulumi." <> T.unpack (contextNameText name) <> ".yaml"

-- | Decide how to make @entry@ read the canonical stack configuration. Never
-- chooses between two different copies: a conflict is refused with both paths.
planStackLink :: FilePath -> FilePath -> CanonicalObservation -> EntryObservation -> StackLinkAction
planStackLink canonical entry canonicalObs entryObs = case (canonicalObs, entryObs) of
  (CanonicalDangling target, _) ->
    RefuseStackLink
      ( "the context's Pulumi stack config "
          <> T.pack canonical
          <> " is a symlink to missing "
          <> T.pack target
          <> "; restore that file (for example, clone the operator repository) before running Pulumi"
      )
  (_, EntryLinksTo _ True) -> case canonicalObs of
    CanonicalAbsent -> CreateEmptyThenLink
    _ -> AlreadyLinked
  (CanonicalAbsent, EntryLinksTo target False) ->
    RefuseStackLink
      ( T.pack entry
          <> " is a symlink to "
          <> T.pack target
          <> ", but the context-owned stack config "
          <> T.pack canonical
          <> " does not exist; if that target is the context's real stack config, link it with: ln -s <target> "
          <> T.pack canonical
      )
  (CanonicalPresent _, EntryLinksTo target False) ->
    RefuseStackLink
      ( T.pack entry
          <> " links to "
          <> T.pack target
          <> ", not to the context-owned stack config "
          <> T.pack canonical
          <> "; remove or relink it after deciding which file is authoritative"
      )
  (CanonicalAbsent, EntryAbsent) -> CreateEmptyThenLink
  (CanonicalAbsent, EntryRegular _) -> AdoptThenLink
  (CanonicalPresent _, EntryAbsent) -> LinkOnly
  (CanonicalPresent stored, EntryRegular local)
    | stored == local -> ReplaceWithLink
    | otherwise ->
        RefuseStackLink
          ( T.pack entry
              <> " differs from the context-owned stack config "
              <> T.pack canonical
              <> "; compare them, keep the authoritative content at the canonical path, and delete the other"
          )

-- | Make @<pulumiDir>/Pulumi.<context>.yaml@ a link to the canonical file,
-- returning the canonical path.
linkContextStackConfig :: ContextName -> FilePath -> IO (Either Text FilePath)
linkContextStackConfig name pulumiDir = do
  canonical <- contextStackConfigPath name
  let entry = stackConfigEntryPath name pulumiDir
  result <- try $ do
    canonicalObs <- observeCanonical canonical
    entryObs <- observeEntry canonical entry
    case planStackLink canonical entry canonicalObs entryObs of
      RefuseStackLink message -> pure (Left message)
      AlreadyLinked -> pure (Right ())
      LinkOnly -> Right <$> link canonical entry
      ReplaceWithLink -> Right <$> link canonical entry
      AdoptThenLink -> do
        createDirectoryIfMissing True (takeDirectory canonical)
        copyFile entry canonical
        Right <$> link canonical entry
      CreateEmptyThenLink -> do
        createDirectoryIfMissing True (takeDirectory canonical)
        BS.writeFile canonical BS.empty
        Right <$> link canonical entry
  pure $ case result of
    Left (err :: IOException) -> Left ("could not link the Pulumi stack config into " <> T.pack pulumiDir <> ": " <> T.pack (show err))
    Right (Left message) -> Left message
    Right (Right ()) -> Right canonical

-- | Install the link atomically: build it beside the entry, then rename over
-- whatever regular file or link was there.
link :: FilePath -> FilePath -> IO ()
link canonical entry = do
  let staging = entry <> ".nagare-link"
  staleLink <- safeIsLink staging
  staleFile <- doesFileExist staging
  when (staleLink || staleFile) (removeFile staging)
  createFileLink canonical staging
  renamePath staging entry

observeCanonical :: FilePath -> IO CanonicalObservation
observeCanonical canonical = do
  isLink <- safeIsLink canonical
  exists <- doesFileExist canonical
  if exists
    then CanonicalPresent <$> BS.readFile canonical
    else
      if isLink
        then CanonicalDangling <$> getSymbolicLinkTarget canonical
        else pure CanonicalAbsent

observeEntry :: FilePath -> FilePath -> IO EntryObservation
observeEntry canonical entry = do
  isLink <- safeIsLink entry
  if isLink
    then do
      target <- getSymbolicLinkTarget entry
      same <- sameRealFile canonical entry
      pure (EntryLinksTo target same)
    else do
      exists <- doesFileExist entry
      if exists then EntryRegular <$> BS.readFile entry else pure EntryAbsent

-- | Whether two paths resolve to the same existing file. A link that points at
-- the canonical path itself counts even before the canonical file exists.
sameRealFile :: FilePath -> FilePath -> IO Bool
sameRealFile canonical entry = do
  target <- getSymbolicLinkTarget entry
  if target == canonical
    then pure True
    else do
      both <- (&&) <$> doesFileExist canonical <*> doesFileExist entry
      if both
        then (==) <$> canonicalizePath canonical <*> canonicalizePath entry
        else pure False

safeIsLink :: FilePath -> IO Bool
safeIsLink path = either (const False) id <$> (try (pathIsSymbolicLink path) :: IO (Either IOException Bool))
