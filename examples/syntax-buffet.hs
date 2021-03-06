class Reader a where
  reader :: List Ch -> a
class Shower a where
  shower :: a -> List Ch
instance Shower Nat where
  shower = \n ->
    case n of
      Zero -> Cons Z Nil
      Succ n -> Cons S (shower n)
data Nat = Succ Nat | Zero
instance Reader Nat where
  reader = \cs ->
    case cs of
      Cons Z Nil -> Zero
      Cons S xs  -> Succ (reader xs)
      _ -> Zero
data List a = Nil | Cons a (List a)
data Ch = A | B | C | D | E | F | G | H | I | J | K | L | M | N | O | P | Q | R | S | T | U | V | W | X | Y | Z
class Equal a where
  equal :: a -> a -> Bool
instance Equal Nat where
  equal =
    \a b ->
      case a of
        Zero ->
          case b of
            Zero -> True
            _ -> False
        Succ n ->
          case b of
            Succ m -> equal n m
            _ -> False
        _ -> False
not = \b -> case b of
              True -> False
              False -> True
notEqual :: Equal a => a -> a -> Bool
notEqual = \x y -> not (equal x y)
main = if not False
          then equal (reader (shower (Succ Zero))) (Succ Zero)
          else False
