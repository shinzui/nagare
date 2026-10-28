-- | The refresh coalescer: one Shomei call per refresh token, a short reuse
-- window, and the real-Shomei reproduction of the reuse revocation it
-- prevents (EP-211 M1).
module RefreshCoalescerSpec (refreshCoalescerTests) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Exception (ErrorCall (..), SomeException, throwIO, try)
import Control.Monad (forM, forM_, replicateM)
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.List (nub)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Access.Auth
import Nagare.Access.Prelude
import Nagare.Access.RefreshCoalescer
import Nagare.Access.ShomeiClient (loginWithShomei, refreshWithShomei)
import RealShomei (withRealShomeiServer)
import Shomei.Account.Dto qualified as ShomeiAccountDTO
import Shomei.Client qualified as ShomeiClient
import Test.Tasty
import Test.Tasty.HUnit

refreshCoalescerTests :: TestTree
refreshCoalescerTests =
  testGroup
    "refresh coalescer"
    [ testCase "concurrent refreshes of one token make one call and share its pair" $ do
        calls <- newIORef (0 :: Int)
        gate <- newEmptyMVar
        coalescer <- newRefreshCoalescer 30 (pure 100)
        let refresh token = do
              n <- atomicModifyIORef' calls (\c -> (c + 1, c + 1))
              readMVar gate
              pure (succeeded (token <> ".rotated." <> tshow n))
        results <- concurrentlyN 8 (coalesceRefresh coalescer refresh "refresh.old") (putMVar gate ())
        readIORef calls >>= (@?= 1)
        nub results @?= [succeeded "refresh.old.rotated.1"]
    , testCase "a late request within the window gets the same pair without a call" $ do
        clock <- newIORef 100
        calls <- newIORef (0 :: Int)
        coalescer <- newRefreshCoalescer 30 (readIORef clock)
        let refresh token = modifyIORef' calls (+ 1) >> (succeeded . (token <>) . tshow <$> readIORef calls)
        coalesceRefresh coalescer refresh "r" >>= (@?= succeeded "r1")
        modifyIORef' clock (+ 29)
        coalesceRefresh coalescer refresh "r" >>= (@?= succeeded "r1")
        readIORef calls >>= (@?= 1)
        modifyIORef' clock (+ 1)
        coalesceRefresh coalescer refresh "r" >>= (@?= succeeded "r2")
        coalesceRefresh coalescer refresh "other" >>= (@?= succeeded "other3")
    , testCase "an unavailable or rejected refresh is not kept" $ do
        answers <- newIORef [LoginUnavailable "down", LoginFailed "no", succeeded "new"]
        coalescer <- newRefreshCoalescer 30 (pure 100)
        let refresh _ = atomicModifyIORef' answers (\as -> (drop 1 as, fromMaybe (LoginFailed "exhausted") (listToMaybe as)))
        coalesceRefresh coalescer refresh "r" >>= (@?= LoginUnavailable "down")
        coalesceRefresh coalescer refresh "r" >>= (@?= LoginFailed "no")
        coalesceRefresh coalescer refresh "r" >>= (@?= succeeded "new")
    , testCase "an exception in the leader reaches its waiters as unavailable and clears the entry" $ do
        entered <- newEmptyMVar
        gate <- newEmptyMVar
        coalescer <- newRefreshCoalescer 30 (pure 100)
        let refresh _ = putMVar entered () >> readMVar gate >> throwIO (ErrorCall "boom")
        leaderDone <- newEmptyMVar
        _ <- forkIO ((try (coalesceRefresh coalescer refresh "r") :: IO (Either SomeException LoginOutcome)) >>= putMVar leaderDone)
        takeMVar entered
        waiterDone <- newEmptyMVar
        _ <- forkIO (coalesceRefresh coalescer (\_ -> pure (succeeded "late")) "r" >>= putMVar waiterDone)
        threadDelay 100000
        putMVar gate ()
        leader <- takeMVar leaderDone
        assertBool "the leader sees its own exception" (either (const True) (const False) leader)
        takeMVar waiterDone >>= (@?= LoginUnavailable "refresh raised")
        coalescerSize coalescer >>= (@?= 0)
    , testCase "settled entries past their window are dropped at the bound" $ do
        clock <- newIORef 100
        coalescer <- newBoundedRefreshCoalescer 30 2 (readIORef clock)
        let refresh token = pure (succeeded token)
        mapM_ (coalesceRefresh coalescer refresh) ["a", "b"]
        modifyIORef' clock (+ 30)
        _ <- coalesceRefresh coalescer refresh "c"
        coalescerSize coalescer >>= (@?= 1)
    , testCase "real Shomei revokes a session refreshed twice at once, and coalescing prevents it" $
        withRealShomeiServer $ \port -> do
          env <- ShomeiClient.shomeiClientEnv ("http://127.0.0.1:" <> show port)
          signUp env
          -- Without the coalescer at most one refresh wins, and the losers'
          -- reuse revokes the session the winner just rotated.
          raw <- signIn env
          racing <- concurrentlyN 8 (refreshWithShomei env raw) (pure ())
          let winners = [tokens | LoginSucceeded tokens <- racing]
          assertBool ("at most one racing refresh may win: " <> show (length winners)) (length winners <= 1)
          forM_ winners $ \tokens ->
            refreshWithShomei env (rotated tokens) >>= \outcome ->
              assertBool ("the race must have revoked the session: " <> show outcome) (not (isSucceeded outcome))
          -- With it every request gets the one rotated pair, and the session lives on.
          coalescer <- newRefreshCoalescer 30 (pure 100)
          token <- signIn env
          shared <- concurrentlyN 8 (coalesceRefresh coalescer (refreshWithShomei env) token) (pure ())
          case nub shared of
            [LoginSucceeded tokens] ->
              refreshWithShomei env (rotated tokens) >>= \outcome ->
                assertBool ("the session must survive: " <> show outcome) (isSucceeded outcome)
            other -> assertFailure ("expected one shared success, got " <> show other)
    ]

-- | Start @n@ copies of @action@ at once, run @release@, and collect every
-- result.
concurrentlyN :: Int -> IO a -> IO () -> IO [a]
concurrentlyN n action release = do
  start <- newEmptyMVar
  dones <- replicateM n newEmptyMVar
  forM_ dones $ \done -> forkIO (readMVar start >> action >>= putMVar done)
  putMVar start ()
  release
  forM dones takeMVar

signUp :: ShomeiClient.ClientEnv -> IO ()
signUp env = do
  result <-
    ShomeiClient.signup
      env
      ShomeiAccountDTO.SignupRequest
        { ShomeiAccountDTO.loginId = "alice"
        , ShomeiAccountDTO.email = Just "alice@example.com"
        , ShomeiAccountDTO.password = alicePassword
        , ShomeiAccountDTO.displayName = "Alice"
        }
  case result of
    Right (ShomeiClient.ApplicationSuccess _) -> pure ()
    Right _ -> assertFailure "signup returned an application error"
    Left err -> assertFailure ("signup failed: " <> show err)

signIn :: ShomeiClient.ClientEnv -> IO Text
signIn env = do
  outcome <- loginWithShomei env LoginCredentials {credentialId = Just "alice", email = Nothing, password = alicePassword}
  case outcome of
    LoginSucceeded tokens -> pure (rotated tokens)
    other -> assertFailure ("login failed: " <> show other)

rotated :: SessionTokens -> Text
rotated tokens = fromMaybe "" (tokens ^. #refreshToken)

alicePassword :: Text
alicePassword = "A-long-random-password-42"

succeeded :: Text -> LoginOutcome
succeeded token = LoginSucceeded SessionTokens {accessToken = "access." <> token, refreshToken = Just token, expiresIn = 900, remembered = True}

isSucceeded :: LoginOutcome -> Bool
isSucceeded (LoginSucceeded _) = True
isSucceeded _ = False

tshow :: Int -> Text
tshow = Text.pack . show
