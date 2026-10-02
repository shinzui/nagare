-- | Preserve the public suite names while keeping each site scenario separate.
module Nagare.Test.SiteInventory (staticInventoryTests) where

import Nagare.Dsl.Prelude
import Nagare.Test.SiteInventory.Preview
  ( previewSiteInventoryTests
  )
import Nagare.Test.SiteInventory.Server
  ( serverSiteInventoryTests
  )
import Nagare.Test.SiteInventory.Static
  ( staticSiteInventoryTests
  )
import Test.Tasty (TestTree)

staticInventoryTests :: [TestTree]
staticInventoryTests = staticSiteInventoryTests <> previewSiteInventoryTests <> serverSiteInventoryTests
