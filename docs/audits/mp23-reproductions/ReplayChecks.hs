module Main where
import InventoryObjectOpsSpec (inventoryObjectOpsTests)
import Test.Tasty (defaultMain)
main :: IO ()
main = defaultMain inventoryObjectOpsTests
