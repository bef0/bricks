{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE NoImplicitPrelude          #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE TypeApplications           #-}

{- |

There are three types of strings in the AST: unquoted, static, and dynamic.

= Why variables are strings

Perhaps counterintuitively, we include variables under the umbrella of "string".
This is because the language itself somewhat conflates the two ideas, and indeed
a casual Bricks user may not even always be aware of which is which.

Consider the following (quite contrived) examples:

> let x = { a = 1; }; in
> let inherit (x) a;  in
> { inherit a; }

> let x = { "a b" = 1; }; in
> let inherit (x) "a b";  in
> { inherit "a b"; }

In the first, @a@ seems quite like a variable; in the second, @"a b"@ feels much
like a string (because we had to quote it, as it contains a space). But the
ASTs for these two expressions are (apart from the name change) identical.

-}
module Bricks.StringExpressions
  (
  -- * Strings
    Str'Static (..)
  , Str'Dynamic (..)
  , Str'1 (..)
  , strDynamic'toList
  , strDynamic'fromList
  , strDynamic'singleton

  -- * String conversions
  , str'dynamicToStatic
  , str'staticToDynamic
  , str'unquotedToDynamic

  ) where

-- Bricks
import Bricks.UnquotedString

-- Bricks internal
import           Bricks.Internal.Prelude
import           Bricks.Internal.Seq            (Seq)
import qualified Bricks.Internal.Seq            as Seq
import           Bricks.Internal.ShowExpression
import           Bricks.Internal.Text           (Text)
import qualified Bricks.Internal.Text           as Text

{- | A fixed string value. We use the description "static" to mean the string
may not contain antiquotation, in contrast with 'Str'Dynamic' which can. -}
data Str'Static = Str'Static Text

{- | A quoted string expression, which may be a simple string like @"hello"@ or
a more complex string containing antiquotation like @"Hello, my name is
${name}!"@. See 'Expr'Str'.

We use the description "dynamic" to mean the string may contain antiquotation,
in contrast with 'Str'Static' which cannot. -}
newtype Str'Dynamic expr =
  Str'Dynamic
    { strDynamic'toSeq :: Seq (Str'1 expr)
    }
  deriving (Monoid, Semigroup)

strDynamic'toList :: Str'Dynamic expr -> [Str'1 expr]
strDynamic'toList =
  Seq.toList . strDynamic'toSeq

strDynamic'fromList :: [Str'1 expr] -> Str'Dynamic expr
strDynamic'fromList =
  Str'Dynamic . Seq.fromList

strDynamic'singleton :: Str'1 expr -> Str'Dynamic expr
strDynamic'singleton =
  Str'Dynamic . Seq.singleton

str'dynamicToStatic :: Str'Dynamic expr -> Maybe Str'Static
str'dynamicToStatic = strDynamic'toList >>> \case
  [Str'1'Literal x] -> Just x
  _                 -> Nothing

str'staticToDynamic :: Str'Static -> Str'Dynamic expr
str'staticToDynamic =
  strDynamic'singleton . Str'1'Literal

str'unquotedToDynamic :: UnquotedString -> Str'Dynamic expr
str'unquotedToDynamic =
  str'staticToDynamic . Str'Static . unquotedString'text

-- | One part of a 'Str'Dynamic'.
data Str'1 expr
  = Str'1'Literal Str'Static
  | Str'1'Antiquote expr

instance ShowExpression Str'Static
  where
    showExpression (Str'Static x) = Text.pack (show @Text x)

instance ShowExpression expr => ShowExpression (Str'Dynamic expr)
  where
    showExpression x =
      Text.unwords ["str", showExpression'list (strDynamic'toList x)]

instance ShowExpression expr => ShowExpression (Str'1 expr)
  where
    showExpression = \case
      Str'1'Literal (Str'Static x) -> showExpression'quoted'text x
      Str'1'Antiquote x -> Text.unwords ["antiquote", showExpression'paren x]

instance Show (Str'Static)
  where
    showsPrec = showsPrec'showExpression

instance ShowExpression expr => Show (Str'Dynamic expr)
  where
    showsPrec = showsPrec'showExpression

instance ShowExpression expr => Show (Str'1 expr)
  where
    showsPrec = showsPrec'showExpression
