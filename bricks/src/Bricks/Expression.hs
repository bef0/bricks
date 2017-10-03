{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE NoImplicitPrelude          #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE TypeApplications           #-}

module Bricks.Expression
  (
  -- * Expressions
    Expression (..)

  -- * Strings
  -- $strings

  -- ** Unquoted strings
  , Str'Unquoted (..)
  , str'unquoted'text

  -- ** Static strings
  , Str'Static (..)
  , str'static'append

  -- ** Dynamic strings
  , Str'Dynamic (..)
  , Str'1 (..)
  , strDynamic'toList
  , strDynamic'fromList
  , strDynamic'singleton
  , str'dynamic'normalize

  -- ** Conversions between types of strings
  , str'dynamic'to'static
  , str'static'to'dynamic
  , str'unquoted'to'static
  , str'unquoted'to'dynamic

  -- * Lists
  , List (..)

  -- * Dicts
  , Dict (..)
  , DictBinding (..)

  -- * Dict lookup
  , Dot (..)
  , expression'applyDots

  -- * Lambdas
  , Lambda (..)

  -- * Function parameters
  , Param (..)
  , DictPattern (..)
  , DictPattern'1 (..)

  -- * Function application
  , Apply (..)
  , expression'applyArgs

  -- * @let@
  , Let (..)
  , LetBinding (..)

  -- * @inherit@
  , Inherit (..)

  ) where

-- Bricks
import Bricks.UnquotedString

-- Bricks internal
import           Bricks.Internal.Prelude
import           Bricks.Internal.Seq            (Seq)
import           Bricks.Internal.ShowExpression
import           Bricks.Internal.Text           (Text)
import           Bricks.Internal.List as List
import qualified Bricks.Internal.Text           as Text
import qualified Bricks.Internal.Seq            as Seq

data Expression
  = Expr'Var Str'Unquoted
      -- ^ A /variable/, such as @x@.
  | Expr'Str Str'Dynamic
      -- ^ A /string/ may be quoted either in the traditional form using a
      -- single double-quote (@"@...@"@):
      --
      -- > "one\ntwo"
      --
      -- or in the \"indented string\" form using two single-quotes
      -- (@''@...@''@):
      --
      -- > ''
      -- >   one
      -- >   two
      -- > ''
      --
      -- Both of these examples reduce to the same value, because leading
      -- whitespace is stripped from indented strings.
      --
      -- Either may contain \"antiquotation\" (also known as \"string
      -- interpolation\") to conveniently concatenate string-valued variables
      -- into the string.
      --
      -- > "Hello, my name is ${name}!"
      --
      -- Normal strings may contain the following escape sequences:
      --
      --  - @\\\\@ → @\\@
      --  - @\\"@  → @"@
      --  - @\\${@ → @${@
      --  - @\\n@  → newline
      --  - @\\r@  → carriage return
      --  - @\\t@  → tab
      --
      -- The indented string form does not interpret any escape sequences.
  | Expr'List List
      -- ^ A /list/ is an ordered collection of expressions.
      --
      -- The empty list:
      --
      -- > [ ]
      --
      -- A list containing three variables:
      --
      -- > [ a b c ]
      --
      -- Lambdas, function applications, @let@-@in@ expressions, and @with@
      -- expressions must be parenthesized when in a list.
      --
      -- > [
      -- >   (x: f x y)
      -- >   (g y)
      -- >   (let a = y; in f a a)
      -- >   (with d; f x a)
      -- > ]
  | Expr'Dict Dict
      -- ^ A /dict/ is an unordered extensional mapping from strings.
      --
      -- The empty dict (with no bindings):
      --
      -- > { }
      --
      -- A dict with two bindings:
      --
      -- > {
      -- >   a = "one";
      -- >   b = "one two";
      -- > }
      --
      -- By default, dict bindings cannot refer to each other. For that, you
      -- need the @rec@ keyword to create a /recursive/ dict.
      --
      -- > rec {
      -- >   a = "one";
      -- >   b = "${a} two";
      -- > }
      --
      -- In either case, the order of the bindings does not matter.
      --
      -- The left-hand side of a dict binding may be a quoted string (in the
      -- traditional @"@...@"@ style, not the indented-string @''@ style),
      -- which make it possible for them to be strings that otherwise couldn't
      -- be expressed unquoted, such as strings containing spaces:
      --
      -- > { "a b" = "c"; }
      --
      -- The left-hand side of a dict may even be an arbitrary expression,
      -- using the @${@ ... @}@ form:
      --
      -- > let x = "a b"; in { ${x} = "c"; }
      --
      -- Dicts also support the @inherit@ keyword:
      --
      -- > { inherit a; inherit (x) c d; }
      --
      -- The previous expression is equivalent to:
      --
      -- > { a = a; c = x.c; d = x.d; }
  | Expr'Dot Dot
      -- ^ A /dot/ expression (named after the @.@ character it contains)
      -- looks up the value in a dict.
      --
      -- The examples in this section all reduce to \"Z\".
      --
      -- > { a = "Z"; }.a
      --
      -- > let x = { a = "Z"; }; in x.a
      --
      -- > { x = { a = "Z"; }; }.x.a
      --
      -- The right-hand side of a dot may be a quoted string (in the
      -- traditional @"@...@"@ style, not the indented-string @''@ style):
      --
      -- > { a = "Z"; }."a"
      --
      -- The right-hand side of a dot may even be an arbitrary expression,
      -- using the @${@ ... @}@ form:
      --
      -- > { a = "Z"; }.${ let b = "a"; in b }
  | Expr'Lambda Lambda
      -- ^ A /lambda/ expression @x: y@ where @x@ is the parameter.
      --
      -- This is a function that turns a name into a greeting:
      --
      -- > name: "Hello, ${name}!"
      --
      -- The function parameter can also be a /dict pattern/, which looks like
      -- this:
      --
      -- > { a, b, c ? "another" }: "Hello, ${a}, ${b}, and ${c}!"
      --
      -- That function accepts a dict and looks up the keys @a@, @b@, and @c@
      -- from it, applying the default value @"another"@ to @c@ if it is not
      -- present in the dict. Dict patterns therefore give us something that
      -- resembles functions with named parameters and default arguments.
      --
      -- By default, a lambda defined with a dict pattern fails to evaluate if
      -- the dict argument contains keys that are not listed in the pattern.
      -- To prevent it from failing, you can end the pattern with @...@:
      --
      -- > ({ a, ... }: x) { a = "1"; b = "2"; }
      --
      -- Every function has a single parameter. If you need multiple
      -- parameters, you have to curry:
      --
      -- > a: b: [ a b ]
  | Expr'Apply Apply
      -- ^ Function /application/:
      --
      -- > f x
      --
      -- If a function has multiple (curried) parameters, you can chain them
      -- together like so:
      --
      -- > f x y z
  | Expr'Let Let
      -- ^ A /let/-/in/ expression:
      --
      -- > let
      -- >   greet = x: "Hello, ${x}!";
      -- >   name = "Chris";
      -- > in
      -- >   greet name
      --
      -- /Let/ bindings, like dict bindings, may also use the @inherit@ keyword.
      --
      -- > let
      -- >   d = { greet = x: "Hello, ${x}!"; name = "Chris"; }
      -- >   inherit (d) greet name;
      -- > in
      -- >   greet name
      --
      -- The previous example also demonstrates how the bindings in a /let/
      -- expression may refer to each other (much like a dict with the @rec@
      -- keyword). As with dicts, the order of the bindings does not matter.


--------------------------------------------------------------------------------
--  Strings overview
--------------------------------------------------------------------------------

{- $strings

There are three types of strings in the AST:

  - 'Str'Unquoted'
  - 'Str'Static'
  - 'Str'Dynamic'

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
like a string (because we had to quote it, as it contains a space). But the ASTs
for these two expressions are (apart from the name change) identical. -}


--------------------------------------------------------------------------------
--  Unquoted strings
--------------------------------------------------------------------------------

data Str'Unquoted = Str'Unquoted UnquotedString

str'unquoted'text :: Str'Unquoted -> Text
str'unquoted'text (Str'Unquoted x) = unquotedString'text x

instance ShowExpression Str'Unquoted
  where
    showExpression = Text.pack . show @Text . str'unquoted'text

instance Show Str'Unquoted
  where
    showsPrec = showsPrec'showExpression


--------------------------------------------------------------------------------
--  Static strings
--------------------------------------------------------------------------------

{- | A fixed string value. We use the description "static" to mean the string
may not contain antiquotation, in contrast with 'Str'Dynamic' which can. -}

data Str'Static = Str'Static Text

str'static'append :: Str'Static -> Str'Static -> Str'Static
str'static'append (Str'Static t1) (Str'Static t2) =
  Str'Static (Text.append t1 t2)

instance Semigroup Str'Static
  where
    (<>) = str'static'append

instance Monoid Str'Static
  where
    mempty = Str'Static mempty
    mappend = (<>)

instance ShowExpression Str'Static
  where
    showExpression (Str'Static x) = Text.pack (show @Text x)

instance Show (Str'Static)
  where
    showsPrec = showsPrec'showExpression


--------------------------------------------------------------------------------
--  Dynamic strings
--------------------------------------------------------------------------------

{- | A quoted string expression, which may be a simple string like @"hello"@ or
a more complex string containing antiquotation like @"Hello, my name is
${name}!"@. See 'Expr'Str'.

We use the description "dynamic" to mean the string may contain antiquotation,
in contrast with 'Str'Static' which cannot. -}

data Str'Dynamic =
  Str'Dynamic
    { strDynamic'toSeq :: Seq Str'1
    }

instance Semigroup Str'Dynamic
  where
    Str'Dynamic x <> Str'Dynamic y = Str'Dynamic (x <> y)

instance Monoid Str'Dynamic
  where
    mempty = Str'Dynamic mempty
    mappend = (<>)

{- | One part of a 'Str'Dynamic'. -}

data Str'1
  = Str'1'Literal Str'Static
  | Str'1'Antiquote Expression

instance ShowExpression Str'Dynamic
  where
    showExpression x =
      Text.unwords ["str", showExpression'list (strDynamic'toList x)]

instance ShowExpression Str'1
  where
    showExpression = \case
      Str'1'Literal (Str'Static x) -> showExpression'quoted'text x
      Str'1'Antiquote x -> Text.unwords ["antiquote", showExpression'paren x]

instance Show Str'Dynamic
  where
    showsPrec = showsPrec'showExpression

instance Show Str'1
  where
    showsPrec = showsPrec'showExpression

strDynamic'toList :: Str'Dynamic -> [Str'1]
strDynamic'toList =
  Seq.toList . strDynamic'toSeq

strDynamic'fromList :: [Str'1] -> Str'Dynamic
strDynamic'fromList =
  Str'Dynamic . Seq.fromList

strDynamic'singleton :: Str'1 -> Str'Dynamic
strDynamic'singleton =
  Str'Dynamic . Seq.singleton

{- | Simplify a dynamic string by combining consecutive pieces of static text.
-}

-- | ==== Examples
--
-- >>> str = Str'1'Literal . Str'Static
-- >>> var = Str'1'Antiquote . Expr'Var . Str'Unquoted . unquotedString'orThrow
--
-- >>> :{
-- >>> str'dynamic'normalize $ Str'Dynamic $ Seq.fromList
-- >>>   [str "a", str "b", var "x", var "y", str "c", str "d"]
-- >>> :}
-- str ["ab", antiquote (var "x"), antiquote (var "y"), "cd"]

str'dynamic'normalize :: Str'Dynamic -> Str'Dynamic
str'dynamic'normalize s =
  s{ strDynamic'toSeq = f (strDynamic'toSeq s) }
  where
    f = Seq.fromList
      . List.concat
      . List.map (\case
          Right xs -> [Str'1'Literal (List.foldr1 str'static'append xs)]
          Left xs -> xs
        )
      . List.groupEither
      . List.map (\case
          Str'1'Literal x -> Right x
          x -> Left x
        )
      . Seq.toList


--------------------------------------------------------------------------------
--  Conversions between types of strings
--------------------------------------------------------------------------------

-- | ==== Examples
--
-- >>> str'dynamic'to'static $ Str'Dynamic $ Seq.fromList []
-- Just ""
--
-- >>> a = Str'1'Literal (Str'Static "hi")
--
-- >>> b = Str'1'Antiquote $ Expr'Var $ Str'Unquoted $ unquotedString'orThrow "x"
--
-- >>> str'dynamic'to'static $ Str'Dynamic $ Seq.fromList [ a ]
-- Just "hi"
--
-- >>> str'dynamic'to'static $ Str'Dynamic $ Seq.fromList [ a, b ]
-- Nothing

str'dynamic'to'static :: Str'Dynamic -> Maybe Str'Static
str'dynamic'to'static = strDynamic'toList >>> \case
  []                -> Just (Str'Static "")
  [Str'1'Literal x] -> Just x
  _                 -> Nothing

str'static'to'dynamic :: Str'Static -> Str'Dynamic
str'static'to'dynamic =
  strDynamic'singleton . Str'1'Literal

str'unquoted'to'static :: Str'Unquoted -> Str'Static
str'unquoted'to'static =
  Str'Static . str'unquoted'text

str'unquoted'to'dynamic :: Str'Unquoted -> Str'Dynamic
str'unquoted'to'dynamic =
  str'static'to'dynamic . str'unquoted'to'static


--------------------------------------------------------------------------------
--  Lambda
--------------------------------------------------------------------------------

{- | A function expression. See 'Expr'Lambda'. -}

data Lambda =
  Lambda
    { lambda'head :: Param
        -- ^ Declaration of the function's parameter
    , lambda'body :: Expression
        -- ^ Body of the function; what it evaluates to
    }


--------------------------------------------------------------------------------
--  Apply
--------------------------------------------------------------------------------

{- | A function application expression. See 'Expr'Apply'. -}

data Apply =
  Apply
    { apply'func :: Expression
        -- ^ The function being called
    , apply'arg :: Expression
        -- ^ The argument to the function
    }

expression'applyArgs
  :: Expression   -- ^ Function
  -> [Expression] -- ^ Args
  -> Expression   -- ^ Function application
expression'applyArgs =
  foldl (\acc b -> Expr'Apply (Apply acc b))


--------------------------------------------------------------------------------
--  Param
--------------------------------------------------------------------------------

{- | A parameter to a 'Lambda'. All functions have a single parameter, but it's
more complicated than that because it may also include dict destructuring. -}

data Param
  = Param'Name Str'Unquoted
      -- ^ A simple single-parameter function
  | Param'DictPattern DictPattern
      -- ^ Dict destructuring, which gives you something resembling multiple
      -- named parameters with default values
  | Param'Both Str'Unquoted DictPattern
      -- ^ Both a param name /and/ a dict pattern, separated by the @\@@
      -- keyword


--------------------------------------------------------------------------------
--  Dict pattern
--------------------------------------------------------------------------------

{- | A type of function parameter ('Param') that does dict destructuring. -}

data DictPattern =
  DictPattern
    { dictPattern'items :: Seq DictPattern'1
        -- ^ The list of keys to pull out of the dict, along with any default
        -- value each may have
    , dictPattern'ellipsis :: Bool
        -- ^ Whether to allow additional keys beyond what is listed in the
        -- items, corresponding to the @...@ keyword
    }

{- | One item within a 'DictPattern'. -}
data DictPattern'1 =
  DictPattern'1
    { dictPattern'1'name :: Str'Unquoted
        -- ^ The name of the key to pull out of the dict
    , dictPattern'1'default :: Maybe Expression
        -- ^ The default value to be used if the key is not present in the dict
    }


--------------------------------------------------------------------------------
--  List
--------------------------------------------------------------------------------

{- | A list literal expression, starting with @[@ and ending with @]@. See
'Expr'List'. -}

newtype List = List (Seq Expression)
  deriving (Monoid, Semigroup)


--------------------------------------------------------------------------------
--  Dict
--------------------------------------------------------------------------------

{- | A dict literal expression, starting with @{@ or @rec {@ and ending with
@}@. See 'Expr'Dict'. -}

data Dict =
  Dict
    { dict'rec :: Bool
        -- ^ Whether the dict is recursive (denoted by the @rec@ keyword)
    , dict'bindings :: Seq DictBinding
        -- ^ The bindings (everything between @{@ and @}@)
    }

{- | A binding of the form @x = y;@ within a 'DictLiteral' or 'LetExpr'. -}

data DictBinding
  = DictBinding'Eq Expression Expression
  | DictBinding'Inherit Inherit


--------------------------------------------------------------------------------
--  Dot
--------------------------------------------------------------------------------

{- | An expression of the form @person.name@ that looks up a key from a dict.
See 'Expr'Dot'. -}

data Dot =
  Dot
    { dot'dict :: Expression
    , dot'key  :: Expression
    }

expression'applyDots
  :: Expression   -- ^ Dict
  -> [Expression] -- ^ Lookups
  -> Expression   -- ^ Dot expression
expression'applyDots =
  foldl (\acc b -> Expr'Dot (Dot acc b))


--------------------------------------------------------------------------------
--  Let
--------------------------------------------------------------------------------

{- | A @let@-@in@ expression. See 'Expr'Let'. -}

data Let =
  Let
    { let'bindings :: Seq LetBinding
        -- ^ The bindings (everything between the @let@ and @in@ keywords)
    , let'value :: Expression
        -- ^ The value (everything after the @in@ keyword)
    }

{- | A semicolon-terminated binding within the binding list of a 'Let'
expression. -}

data LetBinding
  = LetBinding'Eq Str'Static Expression
      -- ^ A binding with an equals sign, of the form @x = y;@
  | LetBinding'Inherit Inherit
      -- ^ A binding using the @inherit@ keyword, of the form @inherit a b;@
      -- or @inherit (x) a b;@


--------------------------------------------------------------------------------
--  Inherit
--------------------------------------------------------------------------------

data Inherit =
  Inherit
    { inherit'source :: Maybe Expression
    , inherit'names :: Seq Str'Static
    }


--------------------------------------------------------------------------------
--  Show
--------------------------------------------------------------------------------

{- | This instance is designed for doctests and REPL experimentation. The format
is designed to strike a balance in verbosity between the derived 'Show'
implementations (which are unwieldily long) and the Bricks language itself
(which is quite terse but unsuitable for demonstrating the parser, as outputting
a Bricks rendering of parse result wouldn't illumunate anyone's understanding of
the AST that the 'Show' instances are here to depict). -}

instance Show Expression        where showsPrec = showsPrec'showExpression

instance Show List              where showsPrec = showsPrec'showExpression
instance Show Dict              where showsPrec = showsPrec'showExpression
instance Show DictBinding       where showsPrec = showsPrec'showExpression
instance Show Dot               where showsPrec = showsPrec'showExpression
instance Show Lambda            where showsPrec = showsPrec'showExpression
instance Show Param             where showsPrec = showsPrec'showExpression
instance Show DictPattern       where showsPrec = showsPrec'showExpression
instance Show DictPattern'1     where showsPrec = showsPrec'showExpression
instance Show Apply             where showsPrec = showsPrec'showExpression
instance Show Let               where showsPrec = showsPrec'showExpression
instance Show LetBinding        where showsPrec = showsPrec'showExpression
instance Show Inherit           where showsPrec = showsPrec'showExpression

instance ShowExpression Expression
  where
    showExpression = \case
      Expr'Var x    -> show'var x
      Expr'Str x    -> showExpression x
      Expr'List x   -> showExpression x
      Expr'Dict x   -> showExpression x
      Expr'Dot x    -> showExpression x
      Expr'Lambda x -> showExpression x
      Expr'Apply x  -> showExpression x
      Expr'Let x    -> showExpression x

instance ShowExpression List
  where
    showExpression (List xs) = Text.unwords ["list", showExpression'list xs]

instance ShowExpression Dict
  where
    showExpression (Dict r bs) =
      Text.unwords
        [if r then "rec'dict" else "dict", showExpression'list bs]

instance ShowExpression DictBinding
  where
    showExpression = \case
      DictBinding'Eq a b ->
        Text.unwords ["binding", showExpression'paren a, showExpression'paren b]
      DictBinding'Inherit x -> showExpression x

instance ShowExpression Dot
  where
    showExpression (Dot a b) =
      Text.unwords ["dot", showExpression'paren a, showExpression'paren b]

instance ShowExpression Lambda
  where
    showExpression (Lambda a b) =
      Text.unwords ["lambda", showExpression'paren a, showExpression'paren b]

instance ShowExpression Param
  where
    showExpression = \case
      Param'Name a -> show'param a
      Param'DictPattern b -> showExpression b
      Param'Both a b ->
        Text.intercalate " <> " [ show'param a, showExpression b ]

instance ShowExpression DictPattern
  where
    showExpression = \case
      DictPattern xs e ->
        Text.intercalate " <> " $
        [Text.unwords ["pattern", showExpression'list xs]] <>
        (if e then ["ellipsis"] else [])

instance ShowExpression DictPattern'1
  where
    showExpression (DictPattern'1 a mb) =
      Text.unwords $
        show'param a :
        maybe [] (\b -> [Text.unwords ["& def", showExpression'paren b]]) mb

instance ShowExpression Apply
  where
    showExpression (Apply a b) =
      Text.unwords ["apply", showExpression'paren a, showExpression'paren b]

instance ShowExpression Let
  where
    showExpression (Let xs y) =
      Text.unwords ["let'in", showExpression'list xs, showExpression'paren y]

instance ShowExpression LetBinding
  where
    showExpression = \case
      LetBinding'Eq a b ->
        Text.unwords ["binding", show'static a, showExpression'paren b]
      LetBinding'Inherit x -> showExpression x

instance ShowExpression Inherit
  where
    showExpression (Inherit mf xs) =
      Text.unwords $
        (maybe ("inherit":) (\a -> ("inherit'from" :)
        . (showExpression'paren a :)) mf) $
        [showExpression'list'text $ fmap f xs]
      where
        f (Str'Static x) = showExpression'quoted'text x

show'static :: Str'Static -> Text
show'static (Str'Static x) =
  Text.unwords ["str", showExpression'quoted'text x]

show'param :: Str'Unquoted -> Text
show'param x =
  Text.unwords ["param", showExpression x]

show'var :: Str'Unquoted -> Text
show'var x =
  Text.unwords ["var", showExpression x]
