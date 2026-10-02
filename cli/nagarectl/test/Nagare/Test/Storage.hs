-- | Storage responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Storage
  ( storageDiscoverTests
  , storageSnapshotTests
  , volumeArchiveTests
  )
where

import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Dsl.Types (RetentionPolicy (Delete, Retain))
import Nagare.Storage.Discover
  ( PVCRow (..)
  , appPVCLabelSelector
  , extractPVCStatus
  , formatStorageTable
  , pvcName
  )
import Nagare.Storage.Restore (safeVolumeExtractPython)
import Nagare.Storage.Snapshot
  ( backupExcludedWarnings
  , snapshotObjectPath
  , snapshotsToPrune
  )
import Nagare.Test.Support.Volumes (mkVol, mkVolWith)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (proc, readCreateProcessWithExitCode)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit
  ( assertBool
  , assertFailure
  , testCase
  , (@?=)
  )

-- ---------------------------------------------------------------------------
-- Nagare.Storage.Snapshot (EP-36)

storageSnapshotTests :: [TestTree]
storageSnapshotTests =
  [ testCase "snapshotObjectPath builds volumes/<app>/<volume>/<ts>.tar.gz" $
      snapshotObjectPath "myapp" "data" "20260609T141503Z"
        @?= "volumes/myapp/data/20260609T141503Z.tar.gz"
  , testCase "snapshotsToPrune keeps the newest N and returns the oldest (newest-first)" $
      snapshotsToPrune 7 nineStamps
        @?= [ "gs://b/volumes/a/d/20260602T000000Z.tar.gz"
            , "gs://b/volumes/a/d/20260601T000000Z.tar.gz"
            ]
  , testCase "snapshotsToPrune is idempotent on an already-pruned set" $
      snapshotsToPrune 7 (drop 2 (reverse nineStamps)) @?= []
  , testCase "snapshotsToPrune keeps everything when count <= N" $
      snapshotsToPrune 7 (take 3 nineStamps) @?= []
  , testCase "backupExcludedWarnings warns for exactly the Delete volume" $
      backupExcludedWarnings "myapp" [mkVolWith Retain "data" "/data", mkVolWith Delete "cache" "/cache"]
        @?= ["warning: volume 'cache' on app 'myapp' is NOT backed up (backup excluded in config)"]
  , testCase "backupExcludedWarnings is empty when all volumes are Retain" $
      backupExcludedWarnings "myapp" [mkVolWith Retain "data" "/data"] @?= []
  ]
  where
    -- Nine fixed-width timestamps; lexicographic == chronological.
    nineStamps =
      [ "gs://b/volumes/a/d/2026060" <> T.pack (show d) <> "T000000Z.tar.gz"
      | d <- [1 .. 9 :: Int]
      ]

storageDiscoverTests :: [TestTree]
storageDiscoverTests =
  [ testCase "appPVCLabelSelector builds the app selector" $
      appPVCLabelSelector "myapp" @?= "nagare.dev/app=myapp"
  , testCase "pvcName is the deterministic nagare-vol-<app>-<vol> form" $
      pvcName "myapp" "data" @?= "nagare-vol-myapp-data"
  , testCase "extractPVCStatus reads one item into a row" $
      extractPVCStatus (BC.pack pvcListJSON)
        @?= Right
          [ PVCRow
              { volume = "data"
              , name = "nagare-vol-myapp-data"
              , size = "1Gi"
              , status = "Bound"
              , persistentVolumeName = "pvc-abc123"
              , nodePath = ""
              }
          ]
  , testCase "extractPVCStatus of empty items is []" $
      extractPVCStatus (BC.pack "{\"items\":[]}") @?= Right []
  , testCase "extractPVCStatus of malformed JSON is Left" $
      case extractPVCStatus (BC.pack "not json") of
        Left _ -> pure ()
        Right r -> assertFailure ("expected Left, got: " <> show r)
  , testCase "formatStorageTable marks a declared-but-missing volume MISSING" $ do
      let vols = [mkVol "data" "1Gi" "/data", mkVol "logs" "2Gi" "/logs"]
          rows =
            [ PVCRow
                { volume = "data"
                , name = "nagare-vol-myapp-data"
                , size = "1Gi"
                , status = "Bound"
                , persistentVolumeName = "pvc-abc123"
                , nodePath = "/var/lib/nagare/local-path/pvc-abc123"
                }
            ]
          out = formatStorageTable "myapp" vols rows
      assertInfix "VOLUME" out
      assertInfix "Bound" out
      assertInfix "MISSING" out
      assertInfix "nagare-vol-myapp-logs" out
  ]
  where
    assertInfix needle hay =
      assertBool ("expected " <> show needle <> " in:\n" <> T.unpack hay) (needle `T.isInfixOf` hay)
    pvcListJSON =
      "{\"items\":[{\"metadata\":{\"name\":\"nagare-vol-myapp-data\",\"labels\":\
      \{\"nagare.dev/volume\":\"data\",\"nagare.dev/app\":\"myapp\",\
      \\"nagare.dev/managed-by\":\"nagarectl\"}},\"spec\":{\"resources\":\
      \{\"requests\":{\"storage\":\"1Gi\"}},\"volumeName\":\"pvc-abc123\"},\
      \\"status\":{\"phase\":\"Bound\"}}]}"

volumeArchiveTests :: [TestTree]
volumeArchiveTests =
  [ testCase "reviewed volume extraction verifies content and rejects unsafe entries before writing" $
      withSystemTempDirectory "nagare-volume-archive" $ \scratch -> do
        let source = scratch </> "source"
            target = scratch </> "target"
            validArchive = scratch </> "valid.tar.gz"
            malicious kind = scratch </> (kind <> ".tar.gz")
            extract archive =
              readCreateProcessWithExitCode
                (proc "python3" ["-c", T.unpack safeVolumeExtractPython, archive, target])
                ""
            makeUnsafe =
              unlines
                [ "import io, sys, tarfile"
                , "kind, path = sys.argv[1:]"
                , "with tarfile.open(path, 'w:gz') as archive:"
                , "    safe = tarfile.TarInfo('would-be-partial.txt')"
                , "    safe.size = 4"
                , "    archive.addfile(safe, io.BytesIO(b'safe'))"
                , "    name = '../../outside.txt' if kind == 'escape' else ('would-be-partial.txt/child' if kind == 'parent' else 'link')"
                , "    member = tarfile.TarInfo(name)"
                , "    if kind == 'link':"
                , "        member.type = tarfile.SYMTYPE"
                , "        member.linkname = '../../outside.txt'"
                , "        archive.addfile(member)"
                , "    else:"
                , "        member.size = 6"
                , "        archive.addfile(member, io.BytesIO(b'escape'))"
                ]
        createDirectoryIfMissing True source
        createDirectoryIfMissing True target
        BS.writeFile (source </> "known.txt") "volume-content-v1"
        (made, _, creationError) <-
          readCreateProcessWithExitCode
            (proc "tar" ["-C", source, "-czf", validArchive, "."])
            ""
        made @?= ExitSuccess
        creationError @?= ""
        (restored, _, restoreError) <- extract validArchive
        restored @?= ExitSuccess
        restoreError @?= ""
        recovered <- BS.readFile (target </> "known.txt")
        recovered @?= "volume-content-v1"
        forM_ ["escape", "link", "parent"] $ \kind -> do
          (created, _, errorText) <-
            readCreateProcessWithExitCode
              (proc "python3" ["-c", makeUnsafe, kind, malicious kind])
              ""
          created @?= ExitSuccess
          errorText @?= ""
          (status, _, _) <- extract (malicious kind)
          assertBool (kind <> " archive was accepted") (status /= ExitSuccess)
          partial <- doesFileExist (target </> "would-be-partial.txt")
          assertBool (kind <> " archive wrote before preflight completed") (not partial)
        outside <- doesFileExist (scratch </> "outside.txt")
        assertBool "archive escaped the target volume" (not outside)
  ]
