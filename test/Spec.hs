{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

-- |

import           Control.Monad
import           Control.Monad.Catch
import           Control.Monad.Logger
import           Control.Monad.Supply
import           Control.Monad.Writer
import           Data.Bifunctor
import           Duet.Context
import           Duet.Infer
import           Duet.Parser
import           Duet.Printer
import           Duet.Renamer
import           Duet.Resolver
import           Duet.Setup
import           Duet.Stepper
import           Duet.Types
import           Test.Hspec

main :: IO ()
main = hspec spec

spec :: SpecWith ()
spec =
  describe
    "Compilation"
    (do it
          "Basic compile and run constant"
          (shouldBe
             (first
                (const ())
                (runNoLoggingT
                   ((evalSupplyT
                       (do decls <- parseText "test" "main = 1"
                           (binds, ctx) <- createContext decls
                           things <-
                             execWriterT
                               (runStepper
                                  100
                                  ctx
                                  (fmap (fmap typeSignatureA) binds)
                                  "main")
                           pure things)
                       [1 ..]))))
             (Right [LiteralExpression () (IntegerLiteral 1)]))
        it
          "Basic compile and run constant lambda"
          (shouldBe
             (first
                (const ())
                (runNoLoggingT
                   ((evalSupplyT
                       (do decls <- parseText "test" "main = (\\x -> x) 1"
                           (binds, ctx) <- createContext decls
                           things <-
                             execWriterT
                               (runStepper
                                  100
                                  ctx
                                  (fmap (fmap typeSignatureA) binds)
                                  "main")
                           pure things)
                       [1 ..]))))
             (Right
                [ ApplicationExpression
                    ()
                    (LambdaExpression
                       ()
                       (Alternative
                          { alternativeLabel = ()
                          , alternativePatterns =
                              [VariablePattern () (ValueName 42 "x")]
                          , alternativeExpression =
                              VariableExpression () (ValueName 42 "x")
                          }))
                    (LiteralExpression () (IntegerLiteral 1))
                , LiteralExpression () (IntegerLiteral 1)
                ])))

-- | Create a context of all renamed, checked and resolved code.
createContext
  :: (MonadSupply Int m, MonadCatch m)
  => [Decl UnkindedType Identifier Location]
  -> m ([BindGroup Type Name (TypeSignature Type Name Location)], Context Type Name Location)
createContext decls = do
  do builtins <-
       setupEnv mempty [] >>=
       traverse
         (const
            (pure
               (Location
                  { locationStartLine = 0
                  , locationStartColumn = 0
                  , locationEndLine = 0
                  , locationEndColumn = 0
                  })))
     let specials = builtinsSpecials builtins
     catch
       (do (typeClasses, signatures, renamedBindings, scope, dataTypes) <-
             renameEverything decls specials builtins
           -- Type class definition
           addedTypeClasses <- addClasses builtins typeClasses
               -- Type checking
           (bindGroups, typeCheckedClasses) <-
             typeCheckModule
               addedTypeClasses
               signatures
               (builtinsSpecialTypes builtins)
               renamedBindings
           -- Type class resolution
           resolvedTypeClasses <-
             resolveTypeClasses
               typeCheckedClasses
               (builtinsSpecialTypes builtins)
           resolvedBindGroups <-
             mapM
               (resolveBindGroup
                  resolvedTypeClasses
                  (builtinsSpecialTypes builtins))
               bindGroups
           -- Create a context of everything
           let ctx =
                 Context
                   { contextSpecialSigs = builtinsSpecialSigs builtins
                   , contextSpecialTypes = builtinsSpecialTypes builtins
                   , contextSignatures = signatures
                   , contextScope = scope
                   , contextTypeClasses = resolvedTypeClasses
                   , contextDataTypes = dataTypes
                   }
           pure (resolvedBindGroups, ctx))
       (throwM . ContextException (builtinsSpecialTypes builtins))

-- | Run the substitution model on the code.
runStepper
  :: forall m. (MonadWriter [Expression Type Name ()] m, MonadSupply Int m, MonadThrow m)
  => Int
  -> Context Type Name Location
  -> [BindGroup Type Name Location]
  -> String
  -> m ()
runStepper maxSteps ctx bindGroups' i = do
  e0 <- lookupNameByString i bindGroups'
  loop 1 "" e0
  where
    loop ::
         Int
      -> String
      -> Expression Type Name Location
      -> m ()
    loop count lastString e = do
      e' <- expandSeq1 ctx bindGroups' e
      let string = printExpression (defaultPrint) e
      when (string /= lastString) (tell [fmap (const ()) e])
      if (fmap (const ()) e' /= fmap (const ()) e) && count < maxSteps
        then do
          newE <-
            renameExpression
              (contextSpecials ctx)
              (contextScope ctx)
              (contextDataTypes ctx)
              e'
          loop (count + 1) string newE
        else pure ()
