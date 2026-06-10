-- | Boot file breaking the import cycle between "Nagare.Dsl.Types" (which carries
-- @tasks :: [Task]@ on 'Nagare.Dsl.Types.Deployment', MasterPlan 10 / EP-52) and
-- "Nagare.Dsl.Task" (which imports the leaf types from "Nagare.Dsl.Types"). It
-- exports the 'Task' type abstractly plus the 'Eq'/'Show' instances that
-- @Deployment@'s @deriving stock (Eq, Show)@ needs; the real definitions live in
-- "Nagare.Dsl.Task".
module Nagare.Dsl.Task (Task) where

data Task

instance Eq Task

instance Show Task
