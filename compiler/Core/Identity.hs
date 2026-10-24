-- Term identities have their own supply; they never consume inference type IDs.
module Core.Identity (Namespace(..), BinderId(..), ExprId(..)) where
newtype Namespace = Namespace String deriving (Eq, Ord, Show)
data BinderId = BinderId !Namespace !Int deriving (Eq, Ord, Show)
data ExprId = ExprId !Namespace !Int deriving (Eq, Ord, Show)
