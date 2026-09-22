module BadIdentityCoerce where
import Data.Coerce (coerce)
import Nagare.Resource.Types
bad :: ContextId -> ResourceId
bad = coerce
