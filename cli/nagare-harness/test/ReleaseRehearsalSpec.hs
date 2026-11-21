{-# OPTIONS_GHC -Werror=unused-imports #-}

-- | EP-229: the transition rehearsal and drill interpreted with the recording
-- fake transport (ReleaseFake). MasterPlan 37 D3: the rehearsal runs on a
-- daemon it creates or one it is given empty, and deletes nothing else.
module ReleaseRehearsalSpec (rehearseTests, drillTests) where

import Data.Aeson (Value, eitherDecodeFileStrict, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isPrefixOf, sort)
import Data.Text qualified as T
import Nagare.Contract.ReleaseImages (overrideVariable, releaseImageKeys)
import Nagare.Contract.V1 (Outcome (..))
import Nagare.Harness.Prelude hiding ((.=))
import Nagare.Harness.Release.Process
import Nagare.Harness.Release.Rehearse
import Nagare.Harness.Release.TransitionDrill
import ReleaseFake
import ReleaseImagesSpec (fixtureImages)
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesFileExist, getPermissions, setOwnerExecutable, setPermissions)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

-- * transition rehearse (scripts/release-rehearse.sh)

rehearseWorld :: FilePath -> Bool -> IO Responder
rehearseWorld root' carriesHelm = do
  let ok out = pure (0, out)
      tool name = root' </> "store" </> name
  forM_ ["bash", "kubectl"] $ \name -> createDirectoryIfMissing True (tool name </> "bin")
  when carriesHelm (createDirectoryIfMissing True (tool "kubectl/bin") >> writeFile (tool "kubectl/bin/helm") "" >> makeExecutable (tool "kubectl/bin/helm"))
  pure $ \command -> case (command ^. #program, command ^. #arguments) of
    ("git", ["rev-parse", "--show-toplevel"]) -> ok (T.pack (root' </> "repo") <> "\n")
    ("git", ["-C", _, "rev-parse", "--verify", _]) -> ok (rev <> "\n")
    ("git", ["-C", _, "show", _]) -> ok (encodeText (object ["releaseImages" .= fixtureImages]))
    ("nix", "build" : rest)
      | "nixpkgs#bash" `elem` rest -> ok (T.pack (unlines [tool "bash", tool "kubectl", tool "no-bin"]))
      | "nixpkgs#kubernetes-helm" `elem` rest -> ok "/nix/store/helm\n"
      | any ("github:" `isPrefixOf`) rest -> ok "/nix/store/source-nagarectl\n"
      | otherwise -> ok "/nix/store/candidate-nagarectl\n"
    ("/nix/store/candidate-nagarectl/bin/nagarectl", ["version", "--json"]) -> ok (versionDocument version' rev)
    ("colima", ["status", "-p", _, "--json"]) -> ok "{\"docker_socket\":\"unix:///colima/rehearsal.sock\",\"cpu\":6}"
    ("/harness/bin/nagare-harness", ["transition", "drill"]) -> do
      let rootDir = case command ^. #environment of
            Exactly entries -> fromMaybe "" (lookup "NAGARE_REHEARSAL_ROOT" entries)
            _ -> ""
      createDirectoryIfMissing True (rootDir </> "evidence")
      BL.writeFile (rootDir </> "evidence/transition-rehearsal.json") (Aeson.encode (rehearsalRecord rev "9.8.6"))
      ok "rehearsal: transition rehearsal OK\n"
    _ -> ok ""
  where
    makeExecutable path = getPermissions path >>= setPermissions path . setOwnerExecutable True

rehearseTests :: TestTree
rehearseTests =
  testGroup
    "transition rehearse"
    [ testCase "builds both CLIs and the tool PATH, starts the drill from an empty environment, and keeps its record" $
        withSystemTempDirectory "rehearse" $ \raw -> do
          root' <- canonicalizePath raw
          let record = root' </> "evidence/transition-rehearsal.json"
          (runtime, world) <- fake [("HOME", root' </> "home"), ("USER", "release"), ("NAGARE_RELEASE_REHEARSAL_RECORD", record), ("NAGARE_CONTEXT", "another")] =<< rehearseWorld root' False
          transitionRehearse runtime (RehearseOptions rev "v9.8.6" (Just (root' </> "work")))
          calls' <- recorded world
          rendered root' calls'
            @?= [ "git rev-parse --show-toplevel"
                , "git -C $T/repo rev-parse --verify " <> T.unpack rev <> "^{commit}"
                , "nix build --no-link --print-out-paths github:shinzui/nagare/v9.8.6#nagarectl"
                , "nix build --no-link --print-out-paths git+file://$T/repo?rev=" <> T.unpack rev <> "#nagarectl"
                , "nix build --no-link --print-out-paths --inputs-from github:shinzui/nagare/v9.8.6 nixpkgs#kubernetes-helm"
                , "nix build --no-link --print-out-paths --inputs-from git+file://$T/repo?rev=" <> T.unpack rev <> " " <> unwords (map ("nixpkgs#" <>) rehearsalTools)
                , "/nix/store/candidate-nagarectl/bin/nagarectl version --json"
                , "git -C $T/repo show " <> T.unpack rev <> ":release.json"
                , "git -C $T/repo show v9.8.6:release.json"
                , "colima start -p nagare-rehearsal-20261029140458 --activate=false --cpus 6 --memory 12 --disk 100 --dns 1.1.1.1 --dns 8.8.8.8"
                , "colima status -p nagare-rehearsal-20261029140458 --json"
                , "/harness/bin/nagare-harness transition drill"
                , "colima delete -p nagare-rehearsal-20261029140458 --force --data"
                ]
          [call ^. #names | call <- calls', call ^. #program == "/harness/bin/nagare-harness"]
            @?= [["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "DOCKER_HOST", "NAGARE_REHEARSAL_SOURCE", "NAGARE_REHEARSAL_TARGET", "NAGARE_REHEARSAL_ROOT", "NAGARE_REHEARSAL_IMAGES"]]
          kept <- eitherDecodeFileStrict @Value record >>= either fail pure
          kept @?= rehearsalRecord rev "9.8.6"
          index <- eitherDecodeFileStrict @Value (root' </> "work/index.json") >>= either fail pure
          fieldAt index ["status"] @?= Just "passed"
          fieldAt index ["children", "drill"] @?= Just "run/index.json"
          fieldAt index ["records", "transitionRehearsal"] @?= Just (Aeson.String (T.pack record))
          wrapper <- readFile (root' </> "work/bin/source-nagarectl")
          wrapper @?= "#!/bin/sh\nPATH=/nix/store/helm/bin:$PATH exec /nix/store/source-nagarectl/bin/nagarectl \"$@\"\n"
    , testCase "a failed drill still deletes the profile it created; a named daemon is used and never deleted (MasterPlan 37 D3)" $
        withSystemTempDirectory "rehearse" $ \raw -> do
          root' <- canonicalizePath raw
          respond <- rehearseWorld root' False
          let refusingDrill command = if command ^. #program == "/harness/bin/nagare-harness" then pure (1, "rehearsal: refused\n") else respond command
          (runtime, world) <- fake [("HOME", root'), ("NAGARE_RELEASE_REHEARSAL_RECORD", root' </> "r.json")] refusingDrill
          refused (transitionRehearse runtime (RehearseOptions rev "9.8.6" (Just (root' </> "work")))) >>= assertMentions "the transition rehearsal failed"
          last . rendered root' <$> recorded world >>= (@?= "colima delete -p nagare-rehearsal-20261029140458 --force --data")
          (named, namedWorld) <- fake [("HOME", root'), ("NAGARE_RELEASE_REHEARSAL_RECORD", root' </> "r.json"), ("NAGARE_REHEARSAL_DOCKER_HOST", "unix:///mine.sock")] =<< rehearseWorld (root' </> "named") False
          transitionRehearse named (RehearseOptions rev "9.8.6" (Just (root' </> "named-work")))
          filter ((== "colima") . (^. #program)) <$> recorded namedWorld >>= (@?= [])
    , testCase "an existing record for the same move is kept without a run; another move's is refused" $
        withSystemTempDirectory "rehearse" $ \raw -> do
          root' <- canonicalizePath raw
          let record = root' </> "transition-rehearsal.json"
          BL.writeFile record (Aeson.encode (rehearsalRecord rev "9.8.6"))
          (runtime, world) <- fake [("HOME", root'), ("NAGARE_RELEASE_REHEARSAL_RECORD", record)] =<< rehearseWorld root' False
          transitionRehearse runtime (RehearseOptions rev "9.8.6" Nothing)
          length <$> recorded world >>= (@?= 2)
          refused (transitionRehearse runtime (RehearseOptions rev "9.8.5" Nothing)) >>= assertMentions "does not record a move from 9.8.5"
    , testCase "a tool PATH that carries a helm, or a source that names no service images, is refused before the drill" $
        withSystemTempDirectory "rehearse" $ \raw -> do
          root' <- canonicalizePath raw
          (runtime, world) <- fake [("HOME", root'), ("NAGARE_RELEASE_REHEARSAL_RECORD", root' </> "r.json")] =<< rehearseWorld root' True
          refused (transitionRehearse runtime (RehearseOptions rev "9.8.6" (Just (root' </> "work")))) >>= assertMentions "carries a helm"
          calls' <- recorded world
          filter ((== "/harness/bin/nagare-harness") . (^. #program)) calls' @?= []
          respond <- rehearseWorld (root' </> "bare") False
          (bare, bareWorld) <- fake [("HOME", root'), ("NAGARE_RELEASE_REHEARSAL_RECORD", root' </> "r.json")] (\c -> if "v9.8.6:release.json" `elem` c ^. #arguments then pure (0, "{}") else respond c)
          refused (transitionRehearse bare (RehearseOptions rev "9.8.6" (Just (root' </> "bare")))) >>= assertMentions "v9.8.6 names no service images"
          filter ((== "/harness/bin/nagare-harness") . (^. #program)) <$> recorded bareWorld >>= (@?= [])
    ]

-- * transition drill (scripts/transition-rehearsal.sh)

drillWorld :: IO Responder
drillWorld = do
  plans <- newIORef (0 :: Int)
  applies <- newIORef (0 :: Int)
  resumes <- newIORef (0 :: Int)
  sentinel <- newIORef ""
  let ok out = pure (0, out)
      source = "/nix/store/source/bin/nagarectl"
      target = "/nix/store/target/bin/nagarectl"
  pure $ \command -> case (command ^. #program, command ^. #arguments) of
    ("docker", ["ps", "-a", "--format", _]) -> ok "elsewhere\n"
    ("docker", ["ps", "--format", _]) -> ok "k3d-registry.localhost\nk3d-nagare-local-server-0\n"
    ("docker", ["info", "--format", _]) -> ok "aarch64\n"
    ("bash", ["/candidate/scripts/publish-local-minio-images.sh"]) -> ok localPins
    ("docker", ["port", "registry-forward", "5000/tcp"]) -> ok "127.0.0.1:15214\n"
    ("curl", ["-s", "-o", "/dev/null", "-m", "2", url]) -> pure (if url == "http://127.0.0.1:15213/" then 0 else 7, "")
    ("docker", ["exec", _, "wget", _, _, _, _]) -> ok "{\"repositories\":[]}\n"
    ("curl", ["-s", "-m", "3", _]) -> ok "{\"repositories\":[]}"
    ("age-keygen", ["-y", _]) -> ok "age1recipient\n"
    (program', ["version"]) | program' `elem` [source, target] -> ok (if program' == source then "nagarectl 9.8.6 (s)\nmore\n" else "nagarectl 9.8.7 (t)\n")
    (program', ["version", "--json"]) -> ok (encodeText (object ["version" .= (if program' == source then "9.8.6" else version' :: Text), "revision" .= (if program' == source then "s" else rev :: Text)]))
    (_, "--context" : "transition" : rest) -> case rest of
      ["context", "create", _, "--mode", "local", _, _, _, _, _, _, _, _, "--use"] -> ok "context transition created\nnow current\n"
      ["platform", "root", "--json"] -> ok "{\"platformVersion\":\"9.8.6\"}"
      ["platform", "bootstrap", "plan", "--out", out] | takeFileName out == "replan" -> writeReview out [] 0 >> ok ""
      ["platform", "bootstrap", "plan", "--out", out] -> do
        modifyIORef' plans (+ 1)
        n <- readIORef plans
        writeReview out (if n == 1 then ["CreateResource", "UpdateResource", "VerifyResource"] else replicate 214 "VerifyResource") 0
        ok ""
      ["platform", "bootstrap", "apply", _, "--yes"] -> ok "converged tx-01\n"
      ["platform", "transition", "plan", "--out", out, "--summary", summary'] -> do
        n <- (+ 1) <$> readIORef applies
        writeReview out (if n == 1 then "UpdateResource" : replicate 213 "VerifyResource" else []) (if n == 1 then 2 else 0)
        writeSummary out summary'
        ok ""
      ["inventory", "apply", _, "--yes", "--contract", "1"] -> modifyIORef' applies (+ 1) >> pure (5, outcomeDocument OutcomeAmbiguous "tx-ab12" (Just "no acknowledgement"))
      ["inventory", "resume", "tx-ab12", "--yes", "--contract", "1"] -> do
        modifyIORef' resumes (+ 1)
        k <- readIORef resumes
        if k == 1 then pure (5, outcomeDocument OutcomeAmbiguous "tx-ab12" (Just "still waiting")) else ok (outcomeDocument OutcomeConverged "tx-ab12" Nothing)
      ["platform", "transition", "commit", "--yes"] -> ok "context transition pinned to 9.8.7\n"
      ["platform", "status", "--json"] -> ok "{\"compatibility\":\"exact\"}"
      ["inventory", "status", "--json"] -> ok "{\"activeTransaction\":null,\"transactionStatus\":null,\"observationComplete\":true,\"accepted\":[]}"
      ["db", "create", "postgres", "rehearsal", _, _, _, _, _, _] -> ok "created\n"
      _ -> pure (2, "fake nagarectl: unexpected " <> T.pack (unwords rest))
    ("kubectl", ["-n", "personal", "get", "statefulset", "rehearsal"]) -> pure (1, "")
    ("kubectl", ["-n", "personal", "get", "secret", _, "-o", _]) -> ok "cmVoZWFyc2Fs"
    ("kubectl", "-n" : "personal" : "exec" : "rehearsal-0" : "--" : "env" : _ : "psql" : rest) -> case reverse rest of
      sql : _
        | "INSERT" `T.isInfixOf` T.pack sql -> writeIORef sentinel (T.takeWhile (/= '\'') (T.drop 1 (T.dropWhile (/= '\'') (snd (T.breakOn "VALUES" (T.pack sql)))))) >> ok ""
        | otherwise -> (,) 0 . (<> "\n") <$> readIORef sentinel
      [] -> ok ""
    _ -> ok ""

-- | What scripts/publish-local-minio-images.sh prints on stdout.
localPins :: Text
localPins = "NAGARE_LOCAL_MINIO_IMAGE=k3d-registry.localhost:5000/nagare-minio@sha256:" <> T.replicate 64 "a" <> "\nNAGARE_LOCAL_MC_IMAGE=k3d-registry.localhost:5000/nagare-mc@sha256:" <> T.replicate 64 "b" <> "\n"

drillOrder :: [String]
drillOrder =
  [ "chmod 700 $T/root $T/root/sops $T/root/sops/age"
  , "docker ps -a --format {{.Names}}"
  , "docker info --format {{.Architecture}}"
  , source "version"
  , target "version"
  , "age-keygen -o $T/root/sops/age/keys.txt"
  , "age-keygen -y $T/root/sops/age/keys.txt"
  , "sops --config $T/root/config/nagare/cluster-secrets/transition/.sops.yaml --encrypt --in-place $T/root/config/nagare/cluster-secrets/transition/grafana-admin.yaml"
  , source "--context transition context create transition --mode local --registry-host k3d-registry.localhost:5000 --base-domain 127-0-0-1.sslip.io --target-platform linux/arm64 --local-object-store http://minio.nagare-system.svc.cluster.local:9000/nagare-backups --use"
  , source "--context transition platform root --json"
  , source "version --json"
  , source "--context transition platform bootstrap plan --out $T/root/reviews/bootstrap-1"
  , source "--context transition platform bootstrap apply $T/root/reviews/bootstrap-1 --yes"
  , "docker ps --format {{.Names}}"
  ]
    <> [ "bash /candidate/scripts/publish-local-minio-images.sh"
       , "curl -s -o /dev/null -m 2 http://127.0.0.1:15213/"
       , "curl -s -o /dev/null -m 2 http://127.0.0.1:15214/"
       , "docker run -d --name registry-forward --network k3d-nagare-local -p 127.0.0.1:15214:5000 alpine/socat TCP-LISTEN:5000,fork,reuseaddr TCP:k3d-registry.localhost:5000"
       , "docker port registry-forward 5000/tcp"
       , "curl -s -m 2 -o /dev/null http://127.0.0.1:15214/v2/"
       , "curl -s -m 3 http://127.0.0.1:15214/v2/_catalog"
       , "docker exec k3d-registry.localhost wget -q -O - http://localhost:5000/v2/_catalog"
       , source "--context transition platform bootstrap plan --out $T/root/reviews/bootstrap-2"
       , source "--context transition inventory status --json"
       , "kubectl -n personal get statefulset rehearsal"
       , source "--context transition db create postgres rehearsal -n personal --recovery-backup postgres-backup --recovery-key-version v1"
       ]
    <> ["kubectl -n personal get secret nagare-db-rehearsal -o jsonpath={.data." <> key <> "}" | key <- ["POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB"]]
    <> [ "kubectl -n personal exec rehearsal-0 -- pg_isready -h 127.0.0.1 -U rehearsal -d rehearsal"
       , psql "CREATE TABLE IF NOT EXISTS transition_sentinel(v text); TRUNCATE transition_sentinel; INSERT INTO transition_sentinel VALUES ('transition 20261029T140458Z');"
       , psql "SELECT v FROM transition_sentinel;"
       , target "--context transition platform transition plan --out $T/root/reviews/transition-1 --summary $T/root/reviews/transition-1.summary.json"
       , target "--context transition inventory apply $T/root/reviews/transition-1 --yes --contract 1"
       , target "--context transition inventory resume tx-ab12 --yes --contract 1"
       , target "--context transition inventory resume tx-ab12 --yes --contract 1"
       , target "--context transition platform transition plan --out $T/root/reviews/transition-2 --summary $T/root/reviews/transition-2.summary.json"
       , target "--context transition platform transition commit --yes"
       , target "--context transition platform status --json"
       , target "--context transition inventory status --json"
       , psql "SELECT v FROM transition_sentinel;"
       , target "--context transition platform bootstrap plan --out $T/root/reviews/replan"
       , source "version --json"
       , target "version --json"
       ]
  where
    source rest = "/nix/store/source/bin/nagarectl " <> rest
    target rest = "/nix/store/target/bin/nagarectl " <> rest
    psql sql = "kubectl -n personal exec rehearsal-0 -- env PGPASSWORD=rehearsal psql -h 127.0.0.1 -U rehearsal -d rehearsal -tAc " <> sql

drillTests :: TestTree
drillTests =
  testGroup
    "transition drill"
    [ testCase "on an empty daemon, bootstraps on the source, publishes the local images once, moves on the candidate resuming an ambiguous apply, and writes the record" $
        withSystemTempDirectory "drill" $ \raw -> do
          root' <- canonicalizePath raw
          let rootDir = root' </> "root"
          respond <- drillWorld
          (runtime, world) <-
            fake
              [ ("HOME", root')
              , ("PATH", "/tools/bin")
              , ("DOCKER_HOST", "unix://" <> root' </> "docker.sock")
              , ("NAGARE_REHEARSAL_SOURCE", "/nix/store/source/bin/nagarectl")
              , ("NAGARE_REHEARSAL_TARGET", "/nix/store/target/bin/nagarectl")
              , ("NAGARE_REHEARSAL_ROOT", rootDir)
              , ("NAGARE_REHEARSAL_IMAGES", "/candidate/scripts/publish-local-minio-images.sh")
              , ("NAGARE_CONTEXT", "another")
              , ("NAGARE_PLATFORM_ROOT", "/checkout")
              , ("KUBECONFIG", "/elsewhere")
              , ("CLOUDSDK_CORE_PROJECT", "elsewhere")
              ]
              respond
          transitionDrill runtime
          calls' <- recorded world
          rendered root' calls' @?= drillOrder
          readIORef (world ^. #pauses) >>= (@?= [20, 20])
          -- no ambient context reaches either release
          forM_ calls' $ \call -> do
            assertBool ("a scrubbed variable reached " <> call ^. #program) (all (`notElem` call ^. #names) ["NAGARE_CONTEXT", "NAGARE_PLATFORM_ROOT", "CLOUDSDK_CORE_PROJECT"])
            assertBool ("the drill's XDG root is missing from " <> call ^. #program) ("XDG_CONFIG_HOME" `elem` call ^. #names)
          let first' = take 1 calls'
              seeded = [call | call <- calls', "db" `elem` call ^. #arguments]
          assertBool "the ambient kubeconfig reached the drill" (all (("KUBECONFIG" `notElem`) . (^. #names)) first')
          map (\call -> "KUBECONFIG" `elem` call ^. #names) seeded @?= [True]
          images <- lines <$> readFile (rootDir </> "images.env")
          sort (map (takeWhile (/= '=')) images) @?= ["NAGARE_LOCAL_MC_IMAGE", "NAGARE_LOCAL_MINIO_IMAGE"]
          assertBool "the image push does not go through the daemon's loopback" (all (elem "NAGARE_LOCAL_REGISTRY_PUSH_HOST") [call ^. #names | call <- calls', call ^. #program == "bash"])
          [image | image <- images, takeWhile (/= '=') image `elem` map (T.unpack . overrideVariable) releaseImageKeys] @?= []
          record <- eitherDecodeFileStrict @Value (rootDir </> "evidence/transition-rehearsal.json") >>= either fail pure
          let field = fieldAt record
          field ["bootstrap", "reviews"] @?= Just (Aeson.Number 1)
          field ["transition", "reviews"] @?= Just (Aeson.Number 1)
          field ["transition", "operations"] @?= Just (Aeson.Number 214)
          field ["sentinel", "seeded"] @?= Just (Aeson.String "transition 20261029T140458Z")
          field ["sentinel", "readBack"] @?= Just (Aeson.String "transition 20261029T140458Z")
          field ["candidate", "revision"] @?= Just (Aeson.String rev)
          field ["source", "version"] @?= Just (Aeson.String "9.8.6")
          field ["inventory", "observationComplete"] @?= Just (Aeson.Bool True)
          field ["platform", "compatibility"] @?= Just (Aeson.String "exact")
          raw' <- readFile (rootDir </> "evidence/transition-rehearsal.json")
          take 2 (lines raw') @?= ["{", "  \"bootstrap\": {"]
          assertBool "the secret file was not encrypted in place" =<< doesFileExist (rootDir </> "config/nagare/cluster-secrets/transition/grafana-admin.yaml")
          takeDirectory rootDir @?= root'
          index <- eitherDecodeFileStrict @Value (rootDir </> "index.json") >>= either fail pure
          fieldAt index ["kind"] @?= Just "drill"
          fieldAt index ["profile"] @?= Just "local-rehearsal"
          fieldAt index ["status"] @?= Just "passed"
          fieldAt index ["candidate", "revision"] @?= Just (Aeson.String rev)
          fieldAt index ["records", "transitionRehearsal"] @?= Just "evidence/transition-rehearsal.json"
          let stages = [stage | Just (Aeson.Array items) <- [fieldAt index ["stages"]], stage <- toList items]
          map (\stage -> (fieldAt stage ["stageId"], fieldAt stage ["converged"])) stages
            @?= [(Just "bootstrap-1", Just (Aeson.Bool False)), (Just "bootstrap-2", Just (Aeson.Bool True)), (Just "transition-1", Just (Aeson.Bool False)), (Just "transition-2", Just (Aeson.Bool True))]
          [(fieldAt attempt' ["attemptId"], fieldAt attempt' ["outcome"]) | stage <- drop 2 (take 3 stages), Just (Aeson.Array attempts') <- [fieldAt stage ["attempts"]], attempt' <- toList attempts']
            @?= [(Just "transition-1/apply", Just "ambiguous"), (Just "transition-1/resume-1", Just "ambiguous"), (Just "transition-1/resume-2", Just "converged")]
    , testCase "the drill scrubs the ambient context but keeps its own inputs" $
        drillEnvironment "/r" [("NAGARE_CONTEXT", "x"), ("NAGARE_REHEARSAL_SOURCE", "s"), ("KUBECONFIG", "k"), ("PULUMI_HOME", "p"), ("NAGARE_X1", "kept"), ("HOME", "/h")]
          @?= [("NAGARE_REHEARSAL_SOURCE", "s"), ("NAGARE_X1", "kept"), ("HOME", "/h"), ("XDG_CONFIG_HOME", "/r/config"), ("XDG_STATE_HOME", "/r/state"), ("XDG_CACHE_HOME", "/r/cache")]
    , testCase "a daemon that already holds a k3d cluster is refused, and nothing is deleted (MasterPlan 37 D3)" $
        withSystemTempDirectory "drill" $ \raw -> do
          root' <- canonicalizePath raw
          respond <- drillWorld
          let held command = case (command ^. #program, command ^. #arguments) of
                ("docker", ["ps", "-a", "--format", _]) -> pure (0, "k3d-nagare-local-server-0\nregistry-forward\n")
                _ -> respond command
          (runtime, world) <- fake [("HOME", root'), ("DOCKER_HOST", "unix:///theirs.sock"), ("NAGARE_REHEARSAL_SOURCE", "/s"), ("NAGARE_REHEARSAL_TARGET", "/t"), ("NAGARE_REHEARSAL_IMAGES", "/i.sh"), ("NAGARE_REHEARSAL_ROOT", root' </> "root")] held
          refused (transitionDrill runtime) >>= assertMentions "already holds a k3d cluster"
          rendered root' <$> recorded world >>= (@?= ["chmod 700 $T/root $T/root/sops $T/root/sops/age", "docker ps -a --format {{.Names}}"])
    , testCase "only the two local object store pins are read from the image script's output" $
        map fst (localImagePins ("Pushed\n" <> localPins <> "NAGARE_LOCAL_MINIO_IMAGE=\n")) @?= ["NAGARE_LOCAL_MINIO_IMAGE", "NAGARE_LOCAL_MC_IMAGE"]
    ]
