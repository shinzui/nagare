{-# LANGUAGE OverloadedStrings #-}

-- | uploads-volume example (EP-37) — a typed Nagare app that stores uploaded
-- files on a durable PersistentVolumeClaim mounted at @/uploads@.
--
-- The single @attachVolume@ line renders a @1Gi@ @local-path@ PVC and mounts it
-- at @/uploads@, so files uploaded to the app survive a pod restart or revision
-- roll. @retention = Retain@ (attachVolume's default) keeps the disk — and the
-- uploads — on app deletion, and includes the volume in the backup story
-- (@nagarectl storage snapshot uploads-volume uploads@). See the README for the
-- upload / durability / snapshot / restore walk-through.
module Main (main) where

import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Presets (attachVolume, webService)
import Nagare.Dsl.Types (Deployment)

deployment :: Either String Deployment
deployment =
  mapLeft show $
    webService "uploads-volume" "us-west1-docker.pkg.dev/tan-nb-exp/nagare/uploads-volume"
      >>= attachVolume "uploads" "1Gi" "/uploads"
  where
    mapLeft f = either (Left . f) Right

main :: IO ()
main = case deployment of
  Left err -> ioError (userError err)
  Right dep -> emitDeployment dep
