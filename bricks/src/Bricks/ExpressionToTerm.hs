{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

{- |

Conversion from 'Expression' (the AST produced by the parser) to 'Term'
(an augmented form of the lambda calculus used for evaluation).

-}
module Bricks.ExpressionToTerm where

-- Bricks
import Bricks.BuiltinFunctions
import Bricks.Expression
import Bricks.Term
import Bricks.Type

-- Bricks internal
import           Bricks.Internal.Prelude
import qualified Bricks.Internal.Seq     as Seq
import           Bricks.Internal.Text    (Text)

-- Containers
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Set (Set)
import qualified Data.Set as Set

expression'to'term :: Expression -> Term
expression'to'term =
  \case
    Expr'Var x -> var'to'term x
    Expr'Str x -> str'to'term x
    Expr'List x -> list'to'term x
    Expr'Dict x -> dict'to'term x
    Expr'Dot x -> dot'to'term x
    Expr'Lambda x -> lambda'to'term x
    Expr'Apply x -> apply'to'term x
    Expr'Let x ->
      undefined

var'to'term :: Var -> Term
var'to'term = Term'Var . var'text

apply'to'term :: Apply -> Term
apply'to'term x =
  expression'to'term (apply'func x) /@\ expression'to'term (apply'arg x)

str'to'term :: Str'Dynamic -> Term
str'to'term x =
  case Seq.toList (strDynamic'toSeq x) of
    [] -> term'data type'string ""
    ys -> foldr1 f $ fmap str'1'to'term ys
  where
    f a b = fn'string'append /@@\ (a, b)

str'1'to'term :: Str'1 -> Term
str'1'to'term = \case
  Str'1'Literal x -> term'data type'string (str'static'text x)
  Str'1'Antiquote x -> expression'to'term x

list'to'term :: List -> Term
list'to'term x =
  Term'List $ fmap expression'to'term (list'expressions x)

dict'to'term :: Dict -> Term
dict'to'term = undefined

dot'to'term :: Dot -> Term
dot'to'term x =
  fn'dict'lookup /@@\ ( expression'to'term (dot'dict x)
                      , expression'to'term (dot'key x)
                      )


--------------------------------------------------------------------------------
--  Converting a lambda expression to a lambda term
--------------------------------------------------------------------------------

lambda'to'term :: Lambda -> Term
lambda'to'term x =
  let
    head = lambda'head x
    body = expression'to'term (lambda'body x)
  in
    case head of
      Param'Name var       -> lambda'to'term'simple var body
      Param'DictPattern dp -> lambda'to'term'dictPattern dp body
      Param'Both var dp    -> lambda'to'term'both var dp body

lambda'to'term'simple :: Var -> Term -> Term
lambda'to'term'simple var body =
  -- For a simple named parameter, the AST translates directly into the
  -- lambda calculus.
  TermPattern'Simple (var'text var) |-> body

lambda'to'term'dictPattern :: DictPattern -> Term -> Term
lambda'to'term'dictPattern dp body =
  -- For dict patterns, we have to do a few more things:
  let
    names = dictPattern'names dp

    -- 1. If there is no ellipsis, add a check to fail if there are
    --    extra keys in the argument.
    h = if dictPattern'ellipsis dp then fn'id
        else fn'dict'disallowExtraKeys names

    -- 2. Insert a dict-merging function to apply default arguments.
    g = fn'dict'merge'preferLeft /@\
          Term'Dict'ReducedKeys (dictPattern'defaults dp)

    f = TermPattern'Dict names |-> body
  in
    fn'comp /@@\ (fn'comp /@@\ (f, g), h)

lambda'to'term'both :: Var -> DictPattern -> Term -> Term
lambda'to'term'both var dp body =
  -- For a named parameter /and/ a dict pattern, we nest the dict pattern
  -- lambda inside a regular lambda.
  lambda'to'term'simple var $ lambda'to'term'dictPattern dp body

dictPattern'names :: DictPattern -> Set Text
dictPattern'names (DictPattern xs _) =
  Set.fromList . fmap f . Seq.toList $ xs
  where
    f = var'text . dictPattern'1'name

dictPattern'defaults :: DictPattern -> Map Text Term
dictPattern'defaults (DictPattern xs _) =
  Map.fromList . catMaybes . fmap f . Seq.toList $ xs
  where
    f :: DictPattern'1 -> Maybe (Text, Term)
    f x = dictPattern'1'default x <&> \d ->
            ( var'text . dictPattern'1'name $ x
            , expression'to'term d )