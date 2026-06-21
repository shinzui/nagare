{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Text (Text)
import qualified Data.Text as Text
import Nagare.Dsl.Broker
import Nagare.Dsl.Config (emitBroker)
import Nagare.Dsl.Types (mkNamespace, mkQuantity)

broker :: Broker
broker =
  Broker
    { name = unsafe (mkBrokerName "events")
    , provider = Redpanda
    , version = unsafe (mkBrokerVersion Redpanda "v26.1.8")
    , namespace = unsafe (mkNamespace "personal")
    , storageSize = unsafe (mkQuantity "5Gi")
    , sizing = defaultBrokerSizing
    , topics =
        [ unsafe
            ( mkBrokerTopic
                (unsafe (mkTopicName "jobs"))
                1
                1
                (Just 86400000)
            )
        ]
    }

main :: IO ()
main = emitBroker broker

unsafe :: Either Text a -> a
unsafe (Right a) = a
unsafe (Left e) = error (Text.unpack e)
