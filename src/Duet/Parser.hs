{-# LANGUAGE TupleSections #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE FlexibleContexts #-}
-- |

module Duet.Parser where

import           Control.Monad
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Data.List
import qualified Data.Map.Strict as M
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import           Duet.Printer
import           Duet.Tokenizer
import           Duet.Types
import           Text.Parsec hiding (satisfy, anyToken)

parseFile :: (MonadIO m, MonadThrow m) => FilePath -> m [Decl UnkindedType Identifier Location]
parseFile fp = do
  t <- liftIO (T.readFile fp)
  parseText fp t

parseText :: MonadThrow m => SourceName -> Text -> m [Decl UnkindedType Identifier Location]
parseText fp inp =
  case parse tokensTokenizer fp (inp) of
    Left e -> throwM (TokenizerError e)
    Right tokens' ->
      case runParser tokensParser 0 fp tokens' of
        Left e -> throwM (ParserError e)
        Right ast -> pure ast

parseTextWith
  :: (Num u, MonadThrow m)
  => Parsec [(Token, Location)] u a -> SourceName -> Text -> m a
parseTextWith p fp inp =
  case parse tokensTokenizer fp (inp) of
    Left e -> throwM (TokenizerError e)
    Right tokens' ->
      case runParser p 0 fp tokens' of
        Left e -> throwM (ParserError e)
        Right ast -> pure ast

parseType' :: Num u => SourceName -> Parsec [(Token, Location)] u b -> Text -> Either ParseError b
parseType' fp p inp =
  case parse tokensTokenizer fp (inp) of
    Left e -> Left e
    Right tokens' ->
      case runParser p 0 fp tokens' of
        Left e -> Left e
        Right ast -> Right ast

tokensParser :: TokenParser [Decl UnkindedType Identifier Location]
tokensParser = moduleParser <* endOfTokens

moduleParser :: TokenParser [Decl UnkindedType Identifier Location]
moduleParser =
  many
    (varfundeclExplicit <|> fmap (uncurry DataDecl) datadecl <|>
     fmap (uncurry ClassDecl) classdecl <|>
     fmap (uncurry InstanceDecl) instancedecl)

classdecl :: TokenParser (Location, Class UnkindedType Identifier Location)
classdecl =
  go <?> "class declaration (e.g. class Show a where show a :: a -> String)"
  where
    go = do
      u <- getState
      loc <- equalToken ClassToken
      setState (locationStartColumn loc)
      (c, _) <-
        consumeToken
          (\case
             Constructor c -> Just c
             _ -> Nothing) <?>
        "new class name e.g. Show"
      vars <- many1 kindableTypeVariable
      mwhere <-
        fmap (const True) (equalToken Where) <|> fmap (const False) endOfDecl
      methods <-
        if mwhere
          then do
            (_, identLoc) <-
              lookAhead
                (consumeToken
                   (\case
                      Variable i -> Just i
                      _ -> Nothing)) <?>
              "class methods e.g. foo :: a -> Int"
            (many1 (methodParser (locationStartColumn identLoc))) <* endOfDecl
          else (pure [])
      setState u
      _ <- (pure () <* satisfyToken (== NonIndentedNewline)) <|> endOfTokens
      pure
        ( loc
        , Class
          { className = Identifier (T.unpack c)
          , classTypeVariables = vars
          , classSuperclasses = []
          , classInstances = []
          , classMethods = M.fromList methods
          })
      where
        endOfDecl =
          (pure () <* satisfyToken (== NonIndentedNewline)) <|> endOfTokens
        methodParser startCol = go' <?> "method signature e.g. foo :: a -> Y"
          where
            go' = do
              u <- getState
              (v, p) <-
                consumeToken
                  (\case
                     Variable i -> Just i
                     _ -> Nothing)
              when
                (locationStartColumn p /= startCol)
                (unexpected
                   ("method name at column " ++
                    show (locationStartColumn p) ++
                    ", it should start at column " ++
                    show startCol ++ " to match the others"))
              setState startCol
              _ <- equalToken Colons <?> "‘::’ for method signature"
              scheme <- parseScheme <?> "method type signature e.g. foo :: Int"
              setState u
              pure (Identifier (T.unpack v), scheme)

kindableTypeVariable :: Stream s m (Token, Location) => ParsecT s Int m (TypeVariable Identifier)
kindableTypeVariable = (unkinded <|> kinded) <?> "type variable (e.g. ‘a’, ‘f’, etc.)"
  where
    kinded =
      kparens
        (do t <- unkinded
            _ <- equalToken Colons
            k <- kindParser
            pure (TypeVariable (typeVariableIdentifier t) k))
      where
        kparens :: TokenParser a -> TokenParser a
        kparens p = g <?> "parens e.g. (x)"
          where
            g = do
              _ <- equalToken OpenParen
              e <-
                p <?> "type with kind inside parentheses e.g. (t :: Type)"
              _ <- equalToken CloseParen <?> "closing parenthesis ‘)’"
              pure e
    unkinded = do
      (v, _) <-
        consumeToken
          (\case
             Variable i -> Just i
             _ -> Nothing) <?>
        "variable name"
      pure (TypeVariable (Identifier (T.unpack v)) StarKind)

parseScheme
  :: Stream s m (Token, Location)
  => ParsecT s Int m (Scheme UnkindedType Identifier UnkindedType)
parseScheme = do
  explicit <-
    fmap (const True) (lookAhead (equalToken ForallToken)) <|> pure False
  if explicit
    then quantified
    else do
      ty@(Qualified _ qt) <- parseQualified
      pure (Forall (nub (collectTypeVariables qt)) ty)
  where
    quantified = do
      _ <- equalToken ForallToken
      vars <- many1 kindableTypeVariable <?> "type variables"
      _ <- equalToken Period
      ty <- parseQualified
      pure (Forall vars ty)

parseSchemePredicate
  :: Stream s m (Token, Location)
  => ParsecT s Int m (Scheme UnkindedType Identifier (Predicate UnkindedType))
parseSchemePredicate = do
  explicit <-
    fmap (const True) (lookAhead (equalToken ForallToken)) <|> pure False
  if explicit
    then quantified
    else do
      ty@(Qualified _ (IsIn _ qt)) <- parseQualifiedPredicate
      pure (Forall (nub (concatMap collectTypeVariables qt)) ty)
  where
    quantified = do
      _ <- equalToken ForallToken
      vars <- many1 kindableTypeVariable <?> "type variables"
      _ <- equalToken Period
      ty <- parseQualifiedPredicate
      pure (Forall vars ty)

parseQualified
  :: Stream s m (Token, Location)
  => ParsecT s Int m (Qualified UnkindedType Identifier (UnkindedType Identifier))
parseQualified = do
  ty <- parsedTypeLike
  (case ty of
     ParsedQualified ps x -> Qualified <$> mapM toUnkindedPred ps <*> toType x
       where toUnkindedPred (IsIn c ts) = IsIn c <$> mapM toType ts
     _ -> do
       t <- toType ty
       pure (Qualified [] t)) <?>
    "qualified type e.g. Show x => x"

parseQualifiedPredicate
  :: Stream s m (Token, Location)
  => ParsecT s Int m (Qualified UnkindedType Identifier (Predicate UnkindedType Identifier))
parseQualifiedPredicate = do
  ty <- parsedTypeLike
  (case ty of
     ParsedQualified ps x -> Qualified <$> mapM toUnkindedPred ps <*> toPredicateUnkinded x
       where toUnkindedPred (IsIn c ts) = IsIn c <$> mapM toType ts
     _ -> do
       t <- toPredicateUnkinded ty
       pure (Qualified [] t)) <?>
    "qualified type e.g. Show x => x"

collectTypeVariables :: UnkindedType i -> [TypeVariable i]
collectTypeVariables =
  \case
     UnkindedTypeConstructor {} -> []
     UnkindedTypeVariable i -> [TypeVariable i StarKind]
     UnkindedTypeApp f x -> collectTypeVariables f ++ collectTypeVariables x

instancedecl :: TokenParser (Location, Instance UnkindedType Identifier Location)
instancedecl =
  go <?> "instance declaration (e.g. instance Show Int where show = ...)"
  where
    go = do
      u <- getState
      loc <- equalToken InstanceToken
      setState (locationStartColumn loc)
      predicate@(Forall _ (Qualified _ (IsIn (Identifier c) _))) <-
        parseSchemePredicate
      mwhere <-
        fmap (const True) (equalToken Where) <|> fmap (const False) endOfDecl
      methods <-
        if mwhere
          then do
            (_, identLoc) <-
              lookAhead
                (consumeToken
                   (\case
                      Variable i -> Just i
                      _ -> Nothing)) <?>
              "instance methods e.g. foo :: a -> Int"
            (many1 (methodParser (locationStartColumn identLoc))) <* endOfDecl
          else (pure [])
      setState u
      _ <- (pure () <* satisfyToken (== NonIndentedNewline)) <|> endOfTokens
      let dictName = "$dict" ++ c
      pure
        ( loc
        , Instance
          { instancePredicate = predicate
          , instanceDictionary =
              Dictionary (Identifier dictName) (M.fromList methods)
          })
      where
        endOfDecl =
          (pure () <* satisfyToken (== NonIndentedNewline)) <|> endOfTokens
        methodParser startCol =
          go' <?> "method implementation e.g. foo = \\x -> f x"
          where
            go' = do
              u <- getState
              (v, p) <-
                consumeToken
                  (\case
                     Variable i -> Just i
                     _ -> Nothing)
              when
                (locationStartColumn p /= startCol)
                (unexpected
                   ("method name at column " ++
                    show (locationStartColumn p) ++
                    ", it should start at column " ++
                    show startCol ++ " to match the others"))
              setState startCol
              _ <- equalToken Equals <?> "‘=’ for method declaration e.g. x = 1"
              e <- expParser
              setState u
              pure (Identifier (T.unpack v), (p, makeAlt (expressionLabel e) e))

parseType :: Stream s m (Token, Location) => ParsecT s Int m (UnkindedType Identifier)
parseType = do
  x <- parsedTypeLike
  toType x

toPredicateUnkinded :: Stream s m t => ParsedType i -> ParsecT s u m (Predicate UnkindedType i)
toPredicateUnkinded = toPredicate >=> go
  where go (IsIn c tys) = IsIn c <$> mapM toType tys

toType :: Stream s m t => ParsedType i -> ParsecT s u m (UnkindedType i)
toType = go
  where
    go =
      \case
        ParsedTypeConstructor i -> pure (UnkindedTypeConstructor i)
        ParsedTypeVariable i -> pure (UnkindedTypeVariable i)
        ParsedTypeApp t1 t2 -> UnkindedTypeApp <$> go t1 <*> go t2
        ParsedQualified {} -> unexpected "qualification context"
        ParsedTuple {} -> unexpected "tuple"

datadecl :: TokenParser (Location, DataType UnkindedType Identifier)
datadecl = go <?> "data declaration (e.g. data Maybe a = Just a | Nothing)"
  where
    go = do
      loc <- equalToken Data
      (v, _) <-
        consumeToken
          (\case
             Constructor i -> Just i
             _ -> Nothing) <?>
        "new type name (e.g. Foo)"
      vs <- many kindableTypeVariable
      _ <- equalToken Equals
      cs <- sepBy1 consp (equalToken Bar)
      _ <- (pure () <* satisfyToken (== NonIndentedNewline)) <|> endOfTokens
      pure (loc, DataType (Identifier (T.unpack v)) vs cs)

kindParser :: Stream s m (Token, Location) => ParsecT s Int m Kind
kindParser = infix'
  where
    infix' = do
      left <- star
      tok <-
        fmap Just (operator <?> ("arrow " ++ curlyQuotes "->")) <|> pure Nothing
      case tok of
        Just (RightArrow, _) -> do
          right <-
            kindParser <?>
            ("right-hand side of function arrow " ++ curlyQuotes "->")
          pure (FunctionKind left right)
        _ -> pure left
      where
        operator =
          satisfyToken
            (\case
               RightArrow {} -> True
               _ -> False)
    star = do
      (c, _) <-
        consumeToken
          (\case
             Constructor c
               | c == "Type" -> Just StarKind
             _ -> Nothing)
      pure c

consp :: TokenParser (DataTypeConstructor UnkindedType Identifier)
consp = do c <- consParser
           slots <- many slot
           pure (DataTypeConstructor c slots)
  where consParser = go <?> "value constructor (e.g. Just)"
          where
            go = do
              (c, _) <-
                consumeToken
                  (\case
                     Constructor c -> Just c
                     _ -> Nothing)
              pure
                (Identifier (T.unpack c))

slot :: TokenParser (UnkindedType Identifier)
slot = consParser <|> variableParser <|> parens parseType
  where
    variableParser = go <?> "type variable (e.g. ‘a’, ‘s’, etc.)"
      where
        go = do
          (v, _) <-
            consumeToken
              (\case
                 Variable i -> Just i
                 _ -> Nothing)
          pure (UnkindedTypeVariable (Identifier (T.unpack v)))
    consParser = go <?> "type constructor (e.g. Maybe)"
      where
        go = do
          (c, _) <-
            consumeToken
              (\case
                 Constructor c -> Just c
                 _ -> Nothing)
          pure (UnkindedTypeConstructor (Identifier (T.unpack c)))

data ParsedType i
  = ParsedTypeConstructor i
  | ParsedTypeVariable i
  | ParsedTypeApp (ParsedType i) (ParsedType i)
  | ParsedQualified [Predicate ParsedType i] (ParsedType i)
  | ParsedTuple [ParsedType i]
  deriving (Show)

parsedTypeLike :: TokenParser (ParsedType Identifier)
parsedTypeLike = infix' <|> app <|> unambiguous
  where
    infix' = do
      left <- (app <|> unambiguous) <?> "left-hand side of function arrow"
      tok <-
        fmap Just (operator <?> ("function arrow " ++ curlyQuotes "->")) <|>
        fmap Just (operator2 <?> ("constraint arrow " ++ curlyQuotes "=>")) <|>
        pure Nothing
      case tok of
        Just (RightArrow, _) -> do
          right <-
            parsedTypeLike <?>
            ("right-hand side of function arrow " ++ curlyQuotes "->")
          pure
            (ParsedTypeApp
               (ParsedTypeApp (ParsedTypeConstructor (Identifier "(->)")) left)
               right)
        Just (Imply, _) -> do
          left' <- parsedTypeToPredicates left <?> "constraints e.g. Show a or (Read a, Show a)"
          right <-
            parsedTypeLike <?>
            ("right-hand side of constraints " ++ curlyQuotes "=>")
          pure (ParsedQualified left' right)
        _ -> pure left
      where
        operator =
          satisfyToken
            (\case
               RightArrow {} -> True
               _ -> False)
        operator2 =
          satisfyToken
            (\case
               Imply {} -> True
               _ -> False)
    app = do
      f <- unambiguous
      args <- many unambiguous
      pure (foldl' ParsedTypeApp f args)
    unambiguous =
      atomicType <|>
      parensTy
        (do xs <- sepBy1 parsedTypeLike (equalToken Comma)
            case xs of
              [x] -> pure x
              _ -> pure (ParsedTuple xs))
    atomicType = consParse <|> varParse
    consParse = do
      (v, _) <-
        consumeToken
          (\case
             Constructor i -> Just i
             _ -> Nothing) <?>
        "type constructor (e.g. Int, Maybe)"
      pure (ParsedTypeConstructor (Identifier (T.unpack v)))
    varParse = do
      (v, _) <-
        consumeToken
          (\case
             Variable i -> Just i
             _ -> Nothing) <?>
        "type variable (e.g. a, f)"
      pure (ParsedTypeVariable (Identifier (T.unpack v)))
    parensTy p = go <?> "parentheses e.g. (T a)"
      where
        go = do
          _ <- equalToken OpenParen
          e <- p <?> "type inside parentheses e.g. (Maybe a)"
          _ <- equalToken CloseParen <?> "closing parenthesis ‘)’"
          pure e

parsedTypeToPredicates :: Stream s m t => ParsedType i -> ParsecT s u m [Predicate ParsedType i]
parsedTypeToPredicates =
  \case
    ParsedTuple xs -> mapM toPredicate xs
    x -> fmap return (toPredicate x)

toPredicate :: Stream s m t => ParsedType i -> ParsecT s u m (Predicate ParsedType i)
toPredicate t =
  case targs t of
    (ParsedTypeConstructor i, vars@(_:_)) -> do
      pure (IsIn i vars)
    _ -> unexpected "non-class constraint"

toVar :: Stream s m t1 => ParsedType t -> ParsecT s u m (ParsedType t)
toVar =
  \case
    v@ParsedTypeVariable {} -> pure v
    _ -> unexpected "non-type-variable"

targs :: ParsedType t -> (ParsedType t, [ParsedType t])
targs e = go e []
  where
    go (ParsedTypeApp f x) args = go f (x : args)
    go f args = (f, args)

varfundecl :: TokenParser (ImplicitlyTypedBinding UnkindedType Identifier Location)
varfundecl = go <?> "variable declaration (e.g. x = 1, f = \\x -> x * x)"
  where
    go = do
      (v, loc) <-
         consumeToken
           (\case
              Variable i -> Just i
              _ -> Nothing) <?>
         "variable name"
      _ <- equalToken Equals <?> "‘=’ for variable declaration e.g. x = 1"
      e <- expParser
      _ <- (pure () <* satisfyToken (==NonIndentedNewline)) <|> endOfTokens
      pure (ImplicitlyTypedBinding loc (Identifier (T.unpack v), loc) [makeAlt loc e])

varfundeclExplicit :: TokenParser (Decl UnkindedType Identifier Location)
varfundeclExplicit =
  go <?> "explicitly typed variable declaration (e.g. x :: Int and x = 1)"
  where
    go = do
      (v0, loc) <-
        consumeToken
          (\case
             Variable i -> Just i
             _ -> Nothing) <?>
        "variable name"
      (tok, _) <- anyToken <?> curlyQuotes "::" ++ " or " ++ curlyQuotes "="
      case tok of
        Colons -> do
          scheme <- parseScheme <?> "type signature e.g. foo :: Int"
          _ <- (pure () <* satisfyToken (== NonIndentedNewline)) <|> endOfTokens
          (v, _) <-
            consumeToken
              (\case
                 Variable i -> Just i
                 _ -> Nothing) <?>
            "variable name"
          when
            (v /= v0)
            (unexpected "variable binding name different to the type signature")
          _ <- equalToken Equals <?> "‘=’ for variable declaration e.g. x = 1"
          e <- expParser
          _ <- (pure () <* satisfyToken (== NonIndentedNewline)) <|> endOfTokens
          pure
            (BindDecl
               loc
               (ExplicitBinding
                  (ExplicitlyTypedBinding loc
                     (Identifier (T.unpack v), loc)
                     scheme
                     [makeAlt loc e])))
        Equals -> do
          e <- expParser
          _ <- (pure () <* satisfyToken (== NonIndentedNewline)) <|> endOfTokens
          pure
            (BindDecl
               loc
               (ImplicitBinding
                  (ImplicitlyTypedBinding
                     loc
                     (Identifier (T.unpack v0), loc)
                     [makeAlt loc e])))
        t -> unexpected (tokenStr t)


makeAlt :: l -> Expression t i l -> Alternative t i l
makeAlt loc e =
  case e of
    LambdaExpression _ alt -> alt
    _ -> Alternative loc [] e

case' :: TokenParser (Expression UnkindedType Identifier Location)
case' = do
  u <- getState
  loc <- equalToken Case
  setState (locationStartColumn loc)
  e <- expParser <?> "expression to do case analysis e.g. case e of ..."
  _ <- equalToken Of
  p <- lookAhead altPat <?> "case pattern"
  alts <- many (altParser (Just e) (locationStartColumn (patternLabel p)))
  setState u
  pure (CaseExpression loc e alts)

altsParser
  :: Stream s m (Token, Location)
  => ParsecT s Int m [(CaseAlt UnkindedType Identifier Location)]
altsParser = many (altParser Nothing 1)

altParser
  :: Maybe (Expression UnkindedType Identifier Location)
  -> Int
  -> TokenParser (CaseAlt UnkindedType Identifier Location)
altParser e' startCol =
  (do u <- getState
      p <- altPat
      when
        (locationStartColumn (patternLabel p) /= startCol)
        (unexpected
           ("pattern at column " ++
            show (locationStartColumn (patternLabel p)) ++
            ", it should start at column " ++
            show startCol ++ " to match the others"))
      setState startCol
      _ <- equalToken RightArrow
      e <- expParser
      setState u
      pure (CaseAlt (Location 0 0 0 0) p e)) <?>
  ("case alternative" ++
   (case e' of
      Just eeee ->
        " e.g.\n\ncase " ++
        printExpression defaultPrint eeee ++
        " of\n  Just bar -> bar"
      Nothing -> ""))

altPat :: TokenParser (Pattern UnkindedType Identifier Location)
altPat = bang <|> varp <|> intliteral <|> consParser <|> stringlit
  where
    bang =
      (BangPattern <$>
       (consumeToken
          (\case
             Bang -> Just Bang
             _ -> Nothing) *>
        patInner)) <?> "bang pattern"
    patInner = parenpat <|> varp <|> intliteral <|> unaryConstructor
    parenpat = go
      where
        go = do
          _ <- equalToken OpenParen
          e <- varp <|> altPat
          _ <- equalToken CloseParen <?> "closing parenthesis ‘)’"
          pure e
    intliteral = go <?> "integer (e.g. 42, 123)"
      where
        go = do
          (c, loc) <-
            consumeToken
              (\case
                 Integer c -> Just c
                 _ -> Nothing)
          pure (LiteralPattern loc (IntegerLiteral c))
    stringlit = go <?> "string (e.g. 42, 123)"
      where
        go = do
          (c, loc) <-
            consumeToken
              (\case
                 String c -> Just c
                 _ -> Nothing)
          pure (LiteralPattern loc (StringLiteral (T.unpack c)))
    varp = go <?> "variable pattern (e.g. x)"
      where
        go = do
          (v, loc) <-
            consumeToken
              (\case
                 Variable i -> Just i
                 _ -> Nothing)
          pure
            (if T.isPrefixOf "_" v
               then WildcardPattern loc (T.unpack v)
               else VariablePattern loc (Identifier (T.unpack v)))
    unaryConstructor = go <?> "unary constructor (e.g. Nothing)"
      where
        go = do
          (c, loc) <-
            consumeToken
              (\case
                 Constructor c -> Just c
                 _ -> Nothing)
          pure (ConstructorPattern loc (Identifier (T.unpack c)) [])
    consParser = go <?> "constructor pattern (e.g. Just x)"
      where
        go = do
          (c, loc) <-
            consumeToken
              (\case
                 Constructor c -> Just c
                 _ -> Nothing)
          args <- many patInner
          pure (ConstructorPattern loc (Identifier (T.unpack c)) args)

expParser :: TokenParser (Expression UnkindedType Identifier Location)
expParser = case' <|> lambda <|> ifParser <|> infix' <|> app <|> atomic
  where
    app = do
      left <- funcOp <?> "function expression"
      right <- many unambiguous <?> "function arguments"
      case right of
        [] -> pure left
        _ -> pure (foldl (ApplicationExpression (Location 0 0 0 0)) left right)
    infix' =
      (do left <- (app <|> unambiguous) <?> "left-hand side of operator"
          tok <- fmap Just (operator <?> "infix operator") <|> pure Nothing
          case tok of
            Just (Operator t, _) -> do
              right <-
                (app <|> unambiguous) <?>
                ("right-hand side of " ++
                 curlyQuotes (T.unpack t) ++ " operator")
              badop <- fmap Just (lookAhead operator) <|> pure Nothing
              let infixexp =
                    InfixExpression
                      (Location 0 0 0 0)
                      left
                      (let i = ((T.unpack t))
                       in (i, VariableExpression (Location 0 0 0 0) (Identifier i)))
                      right
              maybe
                (return ())
                (\op ->
                   unexpected
                     (concat
                        [ tokenString op ++
                          ". When more than one operator is used\n"
                        , "in the same expression, use parentheses, like this:\n"
                        , "(" ++
                          printExpression defaultPrint infixexp ++
                          ") " ++
                          (case op of
                             (Operator i, _) -> T.unpack i ++ " ..."
                             _ -> "* ...") ++
                          "\n"
                        , "Or like this:\n"
                        , printExpressionAppArg defaultPrint left ++
                          " " ++
                          T.unpack t ++
                          " (" ++
                          printExpressionAppArg defaultPrint right ++
                          " " ++
                          case op of
                            (Operator i, _) -> T.unpack i ++ " ...)"
                            _ -> "* ...)"
                        ]))
                badop
              pure infixexp
            _ -> pure left) <?>
      "infix expression (e.g. x * y)"
      where
        operator =
          satisfyToken
            (\case
               Operator {} -> True
               _ -> False)
    funcOp = varParser <|> constructorParser <|> parensExpr
    unambiguous = parensExpr <|> atomic
    parensExpr = parens expParser

operatorParser
  :: Stream s m (Token, Location)
  => ParsecT s Int m (String, Expression t Identifier Location)
operatorParser = do
  tok <-
    satisfyToken
      (\case
         Operator {} -> True
         _ -> False)
  pure
    (case tok of
       (Operator t, _) ->
         let i = (T.unpack t)
         in (i, VariableExpression (Location 0 0 0 0) (Identifier i))
       _ -> error "should be operator...")

lambda :: TokenParser (Expression UnkindedType Identifier Location)
lambda = do
  loc <- equalToken Backslash <?> "lambda expression (e.g. \\x -> x)"
  args <- many1 funcParam <?> "lambda parameters"
  _ <- equalToken RightArrow
  e <- expParser
  pure (LambdaExpression loc (Alternative loc args e))

funcParams :: TokenParser [Pattern UnkindedType Identifier Location]
funcParams = many1 funcParam

funcParam :: TokenParser (Pattern UnkindedType Identifier Location)
funcParam = go <?> "function parameter (e.g. ‘x’, ‘limit’, etc.)"
  where
    go = do
      (v, loc) <-
        consumeToken
          (\case
             Variable i -> Just i
             _ -> Nothing)
      pure (VariablePattern loc (Identifier (T.unpack v)))

atomic :: TokenParser (Expression UnkindedType Identifier Location)
atomic =
  varParser <|> charParser <|> stringParser <|> integerParser <|> decimalParser <|>
  constructorParser
  where
    charParser = go <?> "character (e.g. 'a')"
      where
        go = do
          (c, loc) <-
            consumeToken
              (\case
                 Character c -> Just c
                 _ -> Nothing)
          pure (LiteralExpression loc (CharacterLiteral c))
    stringParser = go <?> "string (e.g. \"a\")"
      where
        go = do
          (c, loc) <-
            consumeToken
              (\case
                 String c -> Just c
                 _ -> Nothing)
          pure (LiteralExpression loc (StringLiteral (T.unpack c)))

    integerParser = go <?> "integer (e.g. 42, 123)"
      where
        go = do
          (c, loc) <-
            consumeToken
              (\case
                 Integer c -> Just c
                 _ -> Nothing)
          pure (LiteralExpression loc (IntegerLiteral c))
    decimalParser = go <?> "decimal (e.g. 42, 123)"
      where
        go = do
          (c, loc) <-
            consumeToken
              (\case
                 Decimal c -> Just c
                 _ -> Nothing)
          pure (LiteralExpression loc (RationalLiteral (realToFrac c)))

constructorParser :: TokenParser (Expression UnkindedType Identifier Location)
constructorParser = go <?> "constructor (e.g. Just)"
  where
    go = do
      (c, loc) <-
        consumeToken
          (\case
             Constructor c -> Just c
             _ -> Nothing)
      pure
        (ConstructorExpression loc (Identifier (T.unpack c)))

parens :: TokenParser a -> TokenParser a
parens p = go <?> "parens e.g. (x)"
  where go = do
         _ <- equalToken OpenParen
         e <- p <?> "expression inside parentheses e.g. (foo)"
         _ <- equalToken CloseParen<?> "closing parenthesis ‘)’"
         pure e

varParser :: TokenParser (Expression UnkindedType Identifier Location)
varParser = go <?> "variable (e.g. ‘foo’, ‘id’, etc.)"
  where
    go = do
      (v, loc) <-
        consumeToken
          (\case
             Variable i -> Just i
             _ -> Nothing)
      pure (if T.isPrefixOf "_" v
               then ConstantExpression loc (Identifier (T.unpack v))
               else VariableExpression loc (Identifier (T.unpack v)))

ifParser :: TokenParser (Expression UnkindedType Identifier Location)
ifParser = go <?> "if expression (e.g. ‘if p then x else y’)"
  where
    go = do
      loc <- equalToken If
      p <- expParser <?> "condition expresion of if-expression"
      _ <- equalToken Then <?> "‘then’ keyword for if-expression"
      e1 <- expParser <?> "‘then’ clause of if-expression"
      _ <- equalToken Else <?> "‘else’ keyword for if-expression"
      e2 <- expParser <?> "‘else’ clause of if-expression"
      pure
        (IfExpression
           loc
           { locationEndLine = locationEndLine (expressionLocation loc e2)
           , locationEndColumn = locationEndColumn (expressionLocation loc e2)
           }
           p
           e1
           e2)
    expressionLocation nil e = foldr const nil e
