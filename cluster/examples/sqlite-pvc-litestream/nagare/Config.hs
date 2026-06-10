{-# LANGUAGE OverloadedStrings #-}

-- | sqlite-pvc-litestream example (EP-37) — a typed Nagare app that keeps a
-- SQLite database on a durable PersistentVolumeClaim, not an ephemeral emptyDir.
--
-- This is the typed-config, real-PVC successor to the raw-Kubernetes
-- @cluster/examples/sqlite-litestream/@ (whose own comment says "a real app
-- would use a PVC on the data disk"). The single @attachVolume@ line is the whole
-- difference: it renders a @1Gi@ @local-path@ PVC and mounts it at @/data@, so a
-- row written to @/data/app.db@ survives a pod restart or revision roll.
--
-- @retention = Retain@ (attachVolume's default) keeps the disk — and the
-- database — when the app is deleted, and includes the volume in the backup
-- story. See the README for the optional Litestream continuous-replication
-- sidecar (the typed model has no sidecar field yet, so it is a documented
-- supplementary step).
module Main (main) where

import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Presets (attachVolume, webService)
import Nagare.Dsl.Types (Deployment)

deployment :: Either String Deployment
deployment =
  mapLeft show $
    webService "sqlite-pvc-litestream" "us-west1-docker.pkg.dev/tan-nb-exp/nagare/sqlite-pvc-litestream"
      >>= attachVolume "data" "1Gi" "/data"
  where
    mapLeft f = either (Left . f) Right

main :: IO ()
main = case deployment of
  Left err -> ioError (userError err)
  Right dep -> emitDeployment dep
