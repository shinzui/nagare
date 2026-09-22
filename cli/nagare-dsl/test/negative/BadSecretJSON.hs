module BadSecretJSON where
import Data.Aeson (encode)
import Data.ByteString.Lazy (ByteString)
import Nagare.Resource.Policy
bad :: RawCredential -> ByteString
bad = encode
