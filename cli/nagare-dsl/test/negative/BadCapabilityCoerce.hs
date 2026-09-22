{-# LANGUAGE DataKinds #-}

module BadCapabilityCoerce where

import Data.Coerce (coerce)
import Nagare.Resource.Reference

bad :: CapabilityRef 'OciImage -> CapabilityRef 'DatabaseConnection
bad = coerce
