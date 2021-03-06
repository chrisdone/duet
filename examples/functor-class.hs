data Maybe a = Nothing | Just a
class Functor (f :: Type -> Type) where
  map :: (a -> b) -> f a -> f b
instance Functor Maybe where
  map = \f m ->
    case m of
      Nothing -> Nothing
      Just a -> Just (f a)
not = \b -> case b of
              True -> False
              False -> True
main = map (\x -> x) (Just 123)
