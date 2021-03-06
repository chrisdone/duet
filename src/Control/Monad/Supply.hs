{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}

-- | Support for computations which consume values from a (possibly infinite)
-- supply. See <http://www.haskell.org/haskellwiki/New_monads/MonadSupply> for
-- details.
--
-- Patched to provide MonadCatch/MonadThrow instead of MonadError.
--
module Control.Monad.Supply
( MonadSupply (..)
, SupplyT
, Supply
, evalSupplyT
, evalSupply
, runSupplyT
, runSupply
) where

import Control.Monad.Catch
import Control.Monad.Identity
#ifndef __GHCJS__
import Control.Monad.Logger
#endif
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Writer

class Monad m => MonadSupply s m | m -> s where
  supply :: m s
  peek :: m s
  exhausted :: m Bool

-- | Supply monad transformer.
newtype SupplyT s m a = SupplyT (StateT [s] m a)
#ifdef __GHCJS__
  deriving (Functor, Applicative, Monad, MonadTrans, MonadIO, MonadFix, MonadCatch, MonadThrow)
#else
  deriving (Functor, Applicative, Monad, MonadTrans, MonadIO, MonadFix, MonadCatch, MonadThrow, MonadLogger)
#endif
-- | Supply monad.
newtype Supply s a = Supply (SupplyT s Identity a)
  deriving (Functor, Applicative, Monad, MonadSupply s, MonadFix)

instance Monad m => MonadSupply s (SupplyT s m) where
  supply =
    SupplyT $ do
      result <- get
      case result of
        (x:xs) -> do
          put xs
          return x
        _ -> error "Exhausted supply in Control.Monad.Supply.hs"
  peek = SupplyT $ gets head
  exhausted = SupplyT $ gets null

instance MonadSupply s m => MonadSupply s (StateT st m) where
  supply = lift supply
  peek = lift peek
  exhausted = lift exhausted

instance MonadSupply s m => MonadSupply s (ReaderT r m) where
  supply = lift supply
  peek = lift peek
  exhausted = lift exhausted

instance (Monoid w, MonadSupply s m) => MonadSupply s (WriterT w m) where
  supply = lift supply
  peek = lift peek
  exhausted = lift exhausted

evalSupplyT :: Monad m => SupplyT s m a -> [s] -> m a
evalSupplyT (SupplyT s) = evalStateT s

evalSupply :: Supply s a -> [s] -> a
evalSupply (Supply s) = runIdentity . evalSupplyT s

runSupplyT :: Monad m => SupplyT s m a -> [s] -> m (a,[s])
runSupplyT (SupplyT s) = runStateT s

runSupply :: Supply s a -> [s] -> (a,[s])
runSupply (Supply s) = runIdentity . runSupplyT s
