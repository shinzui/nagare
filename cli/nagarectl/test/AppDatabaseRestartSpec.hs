-- | EP-209 (BUG-7): ClickHouse without @enable_read_write_grants@ stores the
-- migration user's WRITE ON FILE as the legacy FILE, which a restart reloads
-- as READ and WRITE. That READ is revoked by the next plan, never refused.
module AppDatabaseRestartSpec (appDatabaseRestartTests) where

import AppDatabaseWorldSpec (applySession, converge, observeAll, onUser, quiesceAlpha, replan, sessionReviewFor, setup, user', userMember)
import Data.Generics.Labels ()
import Data.IORef
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Database.AppDatabase.Catalog (grantDriftCode)
import Nagare.Dsl.Database (Engine (..))
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.AppDatabaseSessions
import Nagare.Inventory.AppDatabase (resumeAppDatabaseScope)
import Nagare.Test.World.AppDatabase
import Test.Tasty
import Test.Tasty.HUnit

appDatabaseRestartTests :: TestTree
appDatabaseRestartTests =
  testGroup
    "AppDatabase world ClickHouse server restart (BUG-7)"
    [ testCase "a restart of the server Nagare renders keeps the plan empty" $ do
        (world, ops, members) <- setup ClickHouse id []
        converge ops members >>= expectRight
        modifyIORef' world restartServer
        replan ops members >>= (@?= [])
        observeAll ops members >>= (@?= [])
    , testCase "a legacy restart's READ is revoked by the next plan, also after the setting rolls out" $ do
        (world, ops, members) <- setup ClickHouse id []
        modifyIORef' world (#legacySourceGrants .~ True)
        converge ops members >>= expectRight
        let migrations = sort [userMember members "alpha" "migration", userMember members "beta" "migration"]
            migrationGrants = do
              w <- readIORef world
              pure [sort (u ^. #serverGrants) | (name, u) <- Map.toList (w ^. #users), "_migration" `T.isSuffixOf` name]
            restartAndConverge = do
              modifyIORef' world restartServer
              observeAll ops members >>= (@?= [])
              sort <$> replan ops members >>= (@?= migrations)
              converge ops members >>= expectRight
              migrationGrants >>= (@?= [["WRITE"], ["WRITE"]])
              replan ops members >>= (@?= [])
        restartAndConverge
        restartAndConverge
        -- The rollout turns the setting on; entities stored in the legacy form
        -- reload READ once more, and the converge rewrites them.
        modifyIORef' world (#legacySourceGrants .~ False)
        restartAndConverge
        modifyIORef' world restartServer
        replan ops members >>= (@?= [])
    , testCase "alpha quiesced before a legacy restart resumes and converges (the BUG-7 report)" $ do
        (world, ops, open) <- setup ClickHouse id []
        modifyIORef' world (#legacySourceGrants .~ True)
        converge ops open >>= expectRight
        (_, _, quiesced, nativeQuiesced) <- quiesceAlpha ClickHouse ["runtime"]
        drain <- sessionReviewFor ClickHouse open quiesced DrainStep
        applySession ops drain >>= expectRight
        modifyIORef' world restartServer
        (resumed, _) <- either (assertFailure . show) pure (resumeAppDatabaseScope nativeQuiesced quiesced "t2")
        resume <- sessionReviewFor ClickHouse (drain ^. #after) resumed ResumeStep
        applySession ops resume >>= expectRight
        converge ops (resume ^. #after) >>= expectRight
        replan ops (resume ^. #after) >>= (@?= [])
        after' <- readIORef world
        (^. #login) <$> Map.lookup (user' ClickHouse "alpha" "runtime") (after' ^. #users) @?= Just True
        sort . (^. #serverGrants) <$> Map.lookup (user' ClickHouse "alpha" "migration") (after' ^. #users) @?= Just ["WRITE"]
    , testCase "READ is revoked from a migration user and refused as drift on a runtime user" $ do
        (world, ops, members) <- setup ClickHouse id []
        converge ops members >>= expectRight
        converged <- readIORef world
        modifyIORef' world (onUser (user' ClickHouse "alpha" "runtime") (#serverGrants %~ ("READ" :)))
        refusals <- observeAll ops members
        assertBool (show refusals) (any ((grantDriftCode <> ": " <> user' ClickHouse "alpha" "runtime" <> ": server-wide READ") `T.isPrefixOf`) refusals)
        writeIORef world (onUser (user' ClickHouse "alpha" "migration") (#serverGrants %~ ("READ" :)) converged)
        observeAll ops members >>= (@?= [])
        replan ops members >>= (@?= [userMember members "alpha" "migration"])
        converge ops members >>= expectRight
        final <- readIORef world
        sort . (^. #serverGrants) <$> Map.lookup (user' ClickHouse "alpha" "migration") (final ^. #users) @?= Just ["WRITE"]
    ]
  where
    expectRight = either (assertFailure . T.unpack) pure
