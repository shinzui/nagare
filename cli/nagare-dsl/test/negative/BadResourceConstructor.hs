{-# LANGUAGE OverloadedStrings #-}

module BadResourceConstructor where

import Nagare.Resource.Types

bad :: ResourceId
bad = ResourceId "forged"
