{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLabels #-}
module Main (main) where

import Control.Lens ((&), (.~))
import Data.Bifunctor (first)
import Data.Generics.Labels ()
import Nagare.Dsl.Build (BuildSpec (..), mkTag)
import Nagare.Dsl.Config (emitWorker)
import Nagare.Dsl.Types (mkNamespace)
import Nagare.Dsl.Worker (mkCommand, webWorker)

main :: IO ()
main = either (ioError . userError) emitWorker $ do
  base <- webWorker "ticker" "k3d-registry.localhost:5000/tan-nb-exp/nagare/team-a/hello"
  ns <- first show (mkNamespace "team-a")
  tag <- first show (mkTag "v1")
  cmd <- first show (mkCommand ["sh", "-c", "while true; do echo tick; sleep 10; done"])
  Right (base & #namespace .~ ns & #command .~ Just cmd & #build .~ PrebuiltImage tag)
