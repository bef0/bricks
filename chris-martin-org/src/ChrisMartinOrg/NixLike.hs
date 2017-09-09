{-# LANGUAGE ApplicativeDo, LambdaCase, NamedFieldPuns, NoImplicitPrelude,
             OverloadedStrings, ScopedTypeVariables, ViewPatterns #-}

{- | This module parses and evaluates a Nix-like language. I don't claim that it
/is/ Nix, for two reasons:

1. Nix doesn't actually have a specification.
2. In the interest of laziness, I have only built out enough of it for my
   purpose at hand.

Notable differences from Nix:

- No built-in null, integer, or boolean types
- No @\@@ keyword
- No @builtins@ and no infix operators (@+@, @-@, @//@)
- The concept of "set" is referred to as "dict" (this is not actually a language
  difference, I just use a different word to talk about the same concept)
- No @with@ keyword (todo)
- No comments (todo)

-}
module ChrisMartinOrg.NixLike where

import Control.Applicative ((<|>), (<*), (*>), (<*>), pure)
import Control.Arrow ((>>>))
import Control.Monad ((>>=))
import Text.Parsec ((<?>))
import Text.Parsec.Text (Parser)
import Data.Bool (Bool (..), (&&), (||))
import Data.Char (Char)
import Data.Eq (Eq (..))
import Data.Foldable (Foldable, asum, foldMap, foldl)
import Data.Function (($), (.))
import Data.Functor (Functor (..), (<$>), void)
import Data.Maybe (Maybe (..))
import Data.Ord (Ord (..))
import Data.Semigroup ((<>))
import Data.Text (Text)
import Numeric.Natural (Natural)
import Prelude (fromIntegral, Num (..), undefined)

import qualified Text.Parsec as P
import qualified Data.Char as Char
import qualified Data.Foldable as Foldable
import qualified Data.List as List
import qualified Data.Text as Text

{- $setup

>>> import Prelude (putStrLn, putStr, print, Show, show, IO, Either (..))

We'll use the @parseTest@ function a lot to test parsers. It's a lot like
'P.parseTest' from the parsec library, but it works on parsers of type 'Text'
rather than @'Show' a => a@.

>>> :{
>>> parseTest :: Parser Text -> Text -> IO ()
>>> parseTest p input =
>>>   case P.parse p "" input of
>>>     Left err -> putStr "parse error at " *> print err
>>>     Right x -> putStr (Text.unpack x)
>>> :}

-}


--------------------------------------------------------------------------------
--  Identifiers
--------------------------------------------------------------------------------

{- | An identifier which /must/ be unquoted. For example, in a binding @x = y;@,
the @x@ may be quoted, but the @y@ must be a bare identifier. The bare
identifiers are a subset of the identifiers. -}
newtype BareId =
  BareId
    { bareIdText :: Text
    }

{- | An identifier can be /any/ string. In some cases this means we need to
render it in quotes; see 'isUnquotableText'.

>>> test = putStrLn . Text.unpack . renderIdentifier

>>> test "abc"
abc

>>> test "a\"b"
"a\"b"

>>> test "-ab"
-ab

>>> test ""
""

-}
renderIdentifier :: Text -> Text
renderIdentifier x =
  if isBareIdentifierName x then x else renderQuotedString x

renderBareId :: BareId -> Text
renderBareId (BareId x) = x

renderIdExpr :: StrExpr -> Text
renderIdExpr =
  \case
    StrExpr (Foldable.toList -> [StrExprPart'Literal x]) | isBareIdentifierName x -> x
    x -> renderStrExpr x

{- | Whether an identifier having this name can be rendered without quoting it.
We allow a name to be a bare identifier, and thus to render unquoted, if all
these conditions are met:

- The string is nonempty
- All characters satify 'isBareIdentifierChar'
- The string is not a keyword

>>> isBareIdentifierName "-ab_c"
True

>>> isBareIdentifierName ""
False

>>> isBareIdentifierName "a\"b"
False

>>> isBareIdentifierName "let"
False

-}
isBareIdentifierName :: Text -> Bool
isBareIdentifierName x =
  Text.all isBareIdentifierChar x
  && List.all (/= x) ("" : keywords)

keywords :: [Text]
keywords = ["rec", "let", "in"]

-- | Letters, @-@, and @_@.
isBareIdentifierChar :: Char -> Bool
isBareIdentifierChar c =
  Char.isLetter c || c == '-' || c == '_'

{- |

>>> test = parseTest (bareIdText <$> bareIdP)

>>> test "-ab_c"
-ab_c

>>> test ""
parse error at (line 1, column 1):
unexpected end of input
expecting bare identifier

>>> test "a\"b"
a

-}
bareIdP :: Parser BareId
bareIdP =
  p <?> "bare identifier"
  where
    p = BareId . Text.pack <$> P.many1 (P.satisfy isBareIdentifierChar)

{- |

>>> test = parseTest (renderStrExpr <$> idExprP)

>>> test "a"
"a"

>>> test "\"a\""
"a"

-}
idExprP :: Parser StrExpr
idExprP =
  strExprP <|> (strExpr . bareIdText <$> bareIdP)


--------------------------------------------------------------------------------
--  String
--------------------------------------------------------------------------------

{- | A quoted string expression, which may be a simple string like @"hello"@ or
a more complex string containing antiquotation like @"Hello, my name is
${name}!"@. -}
newtype StrExpr = StrExpr [StrExprPart]

data StrExprPart
  = StrExprPart'Literal Text
  | StrExprPart'Antiquote Expression

{- |

>>> test = putStrLn . Text.unpack . renderStrExpr . StrExpr

>>> test []
""

>>> test [ StrExprPart'Literal "hello" ]
"hello"

>>> test [ StrExprPart'Literal "escape ${ this and \" this" ]
"escape \${ this and \" this"

>>> :{
>>> test [ StrExprPart'Literal "Hello, my name is "
>>>      , StrExprPart'Antiquote (Expr'Id (BareId "name"))
         , StrExprPart'Literal "!"
>>>      ]
>>> :}
"Hello, my name is ${name}!"

-}
renderStrExpr :: StrExpr -> Text
renderStrExpr (StrExpr xs) =
    "\"" <> foldMap f xs <> "\""
  where
    f :: StrExprPart -> Text
    f = \case
      StrExprPart'Literal t -> strEscape t
      StrExprPart'Antiquote e ->
        "${" <> renderExpression RenderContext'Normal e <> "}"

renderQuotedString :: Text -> Text
renderQuotedString x =
  "\"" <> strEscape x <> "\""

strEscape :: Text -> Text
strEscape =
  Text.replace "\"" "\\\"" .
  Text.replace "${" "\\${" .
  Text.replace "\n" "\\n" .
  Text.replace "\r" "\\r" .
  Text.replace "\t" "\\t"

-- | A simple string literal expression with no antiquotation.
strExpr :: Text -> StrExpr
strExpr =
  StrExpr . (\x -> [x]) . StrExprPart'Literal

{- | Parser for any kind of string literal. This includes "normal" string
literals delimited by one double-quote @"@ ('strExprP'normal') and "indented"
string literals delimited by two single-quotes @''@ ('strExprP'indented'). -}
strExprP :: Parser StrExpr
strExprP =
  (strExprP'normal <|> strExprP'indented) <?> "string"


--------------------------------------------------------------------------------
--  Parsing normal strings
--------------------------------------------------------------------------------

{- | Parser for a "normal" string literal, delimited by one double-quote (@"@).
Normal string literals have antiquotation and backslash escape sequences. They
may span multiple lines.

>>> test = parseTest (renderStrExpr <$> strExprP)

>>> test "\"a\""
"a"

-}
strExprP'normal :: Parser StrExpr
strExprP'normal =
  p <?> "normal string literal"
  where
    p = fmap StrExpr $ dP *> P.many (antiquoteP <|> aP) <* dP

    dP = P.char '"'

    aP :: Parser StrExprPart
    aP = StrExprPart'Literal . Text.concat <$> P.many1 bP

    bP :: Parser Text
    bP = asum
      [ strEscapeP
      , Text.singleton <$> (P.try (P.char '$' <* P.notFollowedBy (P.char '{')))
      , Text.singleton <$> P.satisfy (\c -> c /= '$' && c /= '"')
      ]

strEscapeP :: Parser Text
strEscapeP =
  P.char '\\' *> asum
    [ "\\" <$ P.char '\\'
    , "\"" <$ P.char '"'
    , "\n" <$ P.char 'n'
    , "\r" <$ P.char 'r'
    , "\t" <$ P.char 't'
    , "${" <$ P.string "${"
    ]

antiquoteP :: Parser StrExprPart
antiquoteP =
  StrExprPart'Antiquote
    <$> braced (P.string "${") (P.char '}') expressionP
    <?> "antiquoted string"


--------------------------------------------------------------------------------
--  Parsing indented strings
--------------------------------------------------------------------------------

{- | Parser for an "indented string literal," delimited by two single-quotes
@''@ ('strExprP'indented'). Indented string literals have antiquotation but no
backslash escape sequences.

This type of literal is called "indented" because leading whitespace is
intelligently stripped from the string ('stripIndentation'), which makes it
convenient to use these literals for multi-line strings within an indented
expression without the whitespace from indentation ending up as part of the
string.

>>> test = parseTest (renderStrExpr <$> (P.spaces *> strExprP'indented))

>>> test "''hello''"
"hello"

todo - The 'r' quasiquoter from raw-strings-qq might read better here.

>>> :{
>>> test "  ''\n\
>>>      \    one\n\
>>>      \    two\n\
>>>      \  ''"
>>> :}
"one\ntwo"

>>> :{
>>> test "  ''\n\
>>>      \    one\n\
>>>      \\n\
>>>      \    two\n\
>>>      \  ''"
>>> :}
"one\n\ntwo"

-}
strExprP'indented :: Parser StrExpr
strExprP'indented =
  p <?> "indented string literal"
  where
    p = indentedString'joinLines . stripIndentation <$> indentedStringP

{- | An "indented string literal," delimited by two single-quotes @''@. This is
parsed with 'indentedStringP', which is used to implement 'strExprP'indented'.
-}
newtype IndentedString = IndentedString [IndentedStringLine]

-- | One line of an 'IndentedString'. This is parsed with 'indentedStringLineP'.
data IndentedStringLine =
  IndentedStringLine
    { indentedStringLine'leadingSpaces :: Natural
        -- ^ The number of leading space characters. We store this separately
        -- for easier implementation of 'stripIndentation'.
    , indentedStringLine'str :: StrExpr
        -- ^ The rest of the line after any leading spaces.
    }

{- | Parser for a single line of an 'IndentedString'. -}
indentedStringLineP :: Parser IndentedStringLine
indentedStringLineP =
  P.notFollowedBy (P.try (P.string "''")) *> (
    IndentedStringLine
      <$> spaceCountP
      <*> (fmap StrExpr $ P.many $ antiquoteP <|> lP)
      <*  (void (P.char '\n') <|> void (P.try (P.lookAhead (P.string "''"))))
      <?> "line of an indented string literal"
  )

  where
    lP = StrExprPart'Literal . Text.pack <$> P.many1 mP
    mP = asum
      [ P.try $ P.char '\'' <* P.notFollowedBy (P.char '\'')
      , P.try $ P.char '$' <* P.notFollowedBy (P.char '{')
      , P.satisfy (\c -> c /= '\'' && c /= '$' && c /= '\n')
      ]

{- | Reads zero or more space characters and produces the number of them.

>>> test = parseTest (Text.pack . show <$> spaceCountP)

>>> test ""
0

>>> test "a"
0

>>> test "  a  b"
2

-}
spaceCountP :: Parser Natural
spaceCountP =
  fromIntegral . List.length <$> P.many P.space

{- | Parse an indented string, /without/ stripping the indentation. For a
similar parser that does strip indentation, see 'strExprP'indented'. -}
indentedStringP :: Parser IndentedString
indentedStringP =
  fmap IndentedString $
  P.between (P.string "''") (P.string "''") $
  P.many indentedStringLineP

-- | Join 'IndentedStringLine's with newlines interspersed.
indentedString'joinLines :: IndentedString -> StrExpr
indentedString'joinLines (IndentedString xs) =
  StrExpr $ List.concat $ List.intersperse [newline] (f <$> xs)
  where
    newline = StrExprPart'Literal "\n"
    f :: IndentedStringLine -> [StrExprPart]
    f (IndentedStringLine n (StrExpr parts)) =
      StrExprPart'Literal (Text.replicate (fromIntegral n) " ") : parts

{- | Determines whether an 'IndentedStringLine' contains any non-space
characters. This is used to determine whether this line should be considered
when calculating the number of space characters to strip in 'stripIndentation'.
-}
indentedStringLine'nonEmpty :: IndentedStringLine -> Bool
indentedStringLine'nonEmpty =
  \case
    IndentedStringLine{ indentedStringLine'str = StrExpr [] } -> False
    _ -> True

{- | Determine how many characters of whitespace to strip from an indented
string. -}
indentedString'indentationSize :: IndentedString -> Natural
indentedString'indentationSize (IndentedString xs) =
  case List.filter indentedStringLine'nonEmpty xs of
    [] -> 0
    ys -> List.minimum (indentedStringLine'leadingSpaces <$> ys)

{- | Modify an 'IndentedStringLine' by applying a function to its number of
leading spaces. -}
indentedStringLine'modifyLeadingSpaces
  :: (Natural -> Natural) -> IndentedStringLine -> IndentedStringLine
indentedStringLine'modifyLeadingSpaces
  f x@IndentedStringLine{indentedStringLine'leadingSpaces = a} =
  x{ indentedStringLine'leadingSpaces = f a }

{- | Determine the minimum indentation of any nonempty line, and remove that
many space characters from the front of every line. -}
stripIndentation :: IndentedString -> IndentedString
stripIndentation is@(IndentedString xs) =
  let
    b = indentedString'indentationSize is
    f a = if a >= b then a - b else 0
  in
    IndentedString (indentedStringLine'modifyLeadingSpaces f <$> xs)


--------------------------------------------------------------------------------
--  Function
--------------------------------------------------------------------------------

-- | A function expression.
data FuncExpr =
  FuncExpr
    { funcExpr'param :: Param
        -- ^ A declaration of the function's parameter
    , funcExpr'expression :: Expression
        -- ^ The body of the function; what it evaluates to
    }

-- | A function call expression.
data CallExpr =
  CallExpr
    { callExpr'function :: Expression
        -- ^ The function being called
    , callExpr'expression :: Expression
        -- ^ The argument to the function
    }

{- | The parameter to a function. All functions have a single parameter, but
it's more complicated than that because it may also include dict destructuring.
-}
data Param
  = Param'Id BareId
      -- ^ A simple single-parameter function
  | Param'Dict DictParam
      -- ^ Dict destructuring, which gives you something resembling multiple
      -- named parameters with default values

-- | A function parameter that does dict destructuring. See 'Param'.
data DictParam =
  DictParam
    { dictParam'items :: [DictParamItem]
        -- ^ The set of destructured identifiers, along with any default value
        -- each may have
    , dictParam'ellipsis :: Bool
        -- ^ Whether to allow additional keys beyond what is listed in the
        -- items, corresponding to the @...@ keyword
    }

data DictParamItem =
  DictParamItem
    { dictParamItem'variable :: Text
        -- ^ The bound variable
    , dictParamItem'default :: Maybe ParamDefault
        -- ^ The default value to be used if the key is not present in the dict
    }

{- | A default expression to use for a variable bound by a dict destructuring
expression (see 'DictParamItem') if the key is not present in the dict. -}
newtype ParamDefault = ParamDefault Expression

renderParam :: Param -> Text
renderParam =
  \case
    Param'Id x -> renderBareId x <> ":"
    Param'Dict x -> renderDictParam x

{- |

>>> test a b = putStrLn . Text.unpack . renderDictParam $ DictParam a b

>>> test [] False
{ }:

>>> test [] True
{ ... }:

>>> item1 = DictParamItem "x" Nothing
>>> item2 = DictParamItem "y", Just . ParamDefault . Expr'Str . strExpr $ "abc")

>>> renderTest [ item1, item2 ] False
{ x, y ? "abc" }:

>>> renderTest [ item1, item2 ] True
{ x, y ? "abc", ... }:

-}
renderDictParam :: DictParam -> Text
renderDictParam (DictParam items ellipsis) =
  case Foldable.toList items of
    [] -> if ellipsis then "{ ... }:" else "{ }:"
    xs -> "{ " <> Text.intercalate ", " (fmap renderDictParamItem xs) <>
          (if ellipsis then ", ... }:" else " }:")

renderDictParamItem :: DictParamItem -> Text
renderDictParamItem =
  \case
    DictParamItem a Nothing  -> renderIdentifier a
    DictParamItem a (Just b) -> renderIdentifier a <> " " <>
                                renderParamDefault b

renderParamDefault :: ParamDefault -> Text
renderParamDefault (ParamDefault x) =
  "? " <> renderExpression RenderContext'Normal x

renderFuncExpr :: RenderContext -> FuncExpr -> Text
renderFuncExpr cx (FuncExpr a b) =
  if p then "(" <> x <> ")" else x

  where
    x = renderParam a <> " " <>
        renderExpression RenderContext'Normal b

    p = case cx of
      RenderContext'Normal -> False
      RenderContext'List   -> True
      RenderContext'Call1  -> True
      RenderContext'Call2  -> False
      RenderContext'Dot1   -> True

renderCallExpr :: RenderContext -> CallExpr -> Text
renderCallExpr cx (CallExpr a b) =
  if p then "(" <> x <> ")" else x

  where
    x = renderExpression RenderContext'Call1 a <> " " <>
        renderExpression RenderContext'Call2 b

    p = case cx of
      RenderContext'Normal -> False
      RenderContext'List   -> True
      RenderContext'Call1  -> False
      RenderContext'Call2  -> True
      RenderContext'Dot1   -> True

funcExprP :: Parser FuncExpr
funcExprP = undefined

callExprP :: Parser CallExpr
callExprP = undefined

paramP :: Parser Param
paramP = undefined

paramDefaultP :: Parser ParamDefault
paramDefaultP = undefined

dictParamP :: Parser DictParam
dictParamP = undefined

dictParamItemP :: Parser DictParamItem
dictParamItemP = undefined

applyArgs:: Expression -> [Expression] -> Expression
applyArgs =
  foldl (\acc b -> Expr'Call (CallExpr acc b))


--------------------------------------------------------------------------------
--  List
--------------------------------------------------------------------------------

-- | A list literal expression, starting with @[@ and ending with @]@.
data ListLiteral = ListLiteral [Expression]

{- |

>>> :{
>>> renderTest =
>>>   putStrLn . Text.unpack . renderListLiteral . ListLiteral
>>> :}

>>> renderTest []
[ ]

>>> renderTest [ Expr'Id (BareId "true") ]
[ true ]

>>> renderTest [ Expr'Id (BareId "true"), Expr'Id (BareId "false") ]
[ true false ]

>>> call = Expr'Call (CallExpr (Expr'Id (BareId "f")) (Expr'Id (BareId "x")))

>>> renderTest [ call ]
[ (f x) ]

>>> renderTest [ call, Expr'Id (BareId "true") ]
[ (f x) true ]

-}
renderListLiteral :: ListLiteral -> Text
renderListLiteral =
  \case
    ListLiteral (Foldable.toList -> []) -> renderEmptyList
    ListLiteral (Foldable.toList -> values) ->
      "[ " <>
      foldMap (\v -> renderExpression RenderContext'List v <> " ") values <>
      "]"

renderEmptyList :: Text
renderEmptyList = "[ ]"

listLiteralP :: Parser ListLiteral
listLiteralP =
  ListLiteral <$> braced (P.char '[') (P.char ']') expressionListP <?> "list"

--------------------------------------------------------------------------------
--  Dict
--------------------------------------------------------------------------------

{- | A dict literal expression, starting with @{@ or @rec {@ and ending with
@}@. -}
data DictLiteral =
  DictLiteral
    { dictLiteral'rec :: Bool
        -- ^ Whether the dict is recursive (denoted by the @rec@ keyword)
    , dictLiteral'bindings :: [Binding]
        -- ^ The bindings (everything between @{@ and @}@)
    }

-- | An expression of the form @person.name@ that looks up a key from a dict.
data Dot = Dot
  { dot'dict :: Expression
  , dot'key :: StrExpr
  }

renderDictLiteral :: DictLiteral -> Text
renderDictLiteral =
  \case
    DictLiteral _ [] -> renderEmptyDict
    DictLiteral True bs -> "rec { " <> renderBindingList bs <> " }"
    DictLiteral False bs -> "{ " <> renderBindingList bs <> " }"

renderEmptyDict :: Text
renderEmptyDict = "{ }"

renderDot :: Dot -> Text
renderDot (Dot a b) =
  renderExpression RenderContext'Dot1 a <> "." <> renderIdExpr b

dictLiteralP :: Parser DictLiteral
dictLiteralP =
  asum
    [ DictLiteral False <$> dictLiteralP'noRec
    , DictLiteral True <$> (P.string "rec" *> P.spaces *> dictLiteralP'noRec)
    ]

dictLiteralP'noRec :: Parser [Binding]
dictLiteralP'noRec =
  do
    _ <- P.char '{' *> P.spaces
    a <- bindingP `sepBy1` P.spaces
    _ <- P.spaces *> P.char '}'
    pure a

{- | Parser for a chain of dict lookups (like @.a.b.c@).

>>> test = parseTest (Text.intercalate "\n" . fmap renderStrExpr <$> dotsP)

>>> test ""

>>> test ".a"
"a"

>>> test ".\"a\""
"a"

>>> test ".a . b c"
"a"
"b"

>>> test ".a.\"b\""
"a"
"b"

-}
dotsP :: Parser [StrExpr]
dotsP = dotP `sepBy` P.spaces <?> "dots"

{- |

>>> test = parseTest (renderStrExpr <$> dotP)

>>> test ".a"
"a"

>>> test ". a . b"
"a"

>>> test ". \"a\""
"a"

>>> test ". \"a\".b"
"a"

-}
dotP :: Parser StrExpr
dotP =
  P.char '.' *> P.spaces *> idExprP

applyDots :: Expression -> [StrExpr] -> Expression
applyDots =
  foldl (\acc b -> Expr'Dot (Dot acc b))


--------------------------------------------------------------------------------
--  Let
--------------------------------------------------------------------------------

-- | A @let@-@in@ expression.
data LetExpr =
  LetExpr
    { letExpr'bindings :: [Binding]
        -- ^ The bindings (everything between the @let@ and @in@ keywords)
    , letExpr'value :: Expression
        -- ^ The value (everything after the @in@ keyword)
    }

renderLetExpr :: LetExpr -> Text
renderLetExpr (LetExpr bs x) =
  if List.null bs
    then "let in " <> body
    else "let " <> renderBindingList bs <> " in " <> body
  where
    body = renderExpression RenderContext'Normal x

letExprP :: Parser LetExpr
letExprP = undefined


--------------------------------------------------------------------------------
--  Binding
--------------------------------------------------------------------------------

-- | A binding of the form @x = y;@ within a 'DictLiteral' or 'LetExpr'.
data Binding = Binding StrExpr Expression

renderBinding :: Binding -> Text
renderBinding (Binding a b) =
  renderIdExpr a <> " = " <> renderExpression RenderContext'Normal b <> ";"

renderBindingList :: Foldable f => f Binding -> Text
renderBindingList =
  Foldable.toList >>> \case
    [] -> ""
    bs -> Text.intercalate " " (fmap renderBinding bs)

bindingP :: Parser Binding
bindingP = undefined

bindingMapP :: Parser [Binding]
bindingMapP = undefined


--------------------------------------------------------------------------------
--  Expression
--------------------------------------------------------------------------------

data Expression
  = Expr'Str  StrExpr
  | Expr'List ListLiteral
  | Expr'Dict DictLiteral
  | Expr'Dot  Dot
  | Expr'Id   BareId
  | Expr'Func FuncExpr
  | Expr'Call CallExpr
  | Expr'Let  LetExpr

renderExpression :: RenderContext -> Expression -> Text
renderExpression c =
  \case
    Expr'Str  x -> renderStrExpr x
    Expr'Dict x -> renderDictLiteral x
    Expr'List x -> renderListLiteral x
    Expr'Id   x -> renderBareId x
    Expr'Dot  x -> renderDot x
    Expr'Func x -> renderFuncExpr c x
    Expr'Call x -> renderCallExpr c x
    Expr'Let  x -> renderLetExpr x

{- | The primary, top-level expression parser. This is what you use to parse a
@.nix@ file.

>>> test = parseTest (renderExpression RenderContext'Normal <$> expressionP)

>>> test "[ true false ]"
[ true false ]

>>> test "f x"
f x

>>> test "[ true (f x) ]"
"[ true (f x) ]"

>>> [ 123 "abc" (f { x = y; }) ]
[ 123 "abc" (f { x = y; }) ]

>>> [ 123 "abc" f { x = y; } ]
[ 123 "abc" f { x = y; } ]

-}
expressionP :: Parser Expression
expressionP =
  asum
    [ fmap Expr'Func funcExprP
    , expressionListP >>= \case
        [] -> P.parserZero
        f : args -> pure $ applyArgs f args
    ]

{- | Parser for a list of expressions in a list literal (@[ x y z ]@) or in a
chain of function arguments (@f x y z@).

>>> :{
>>> test = parseTest $
>>>   fmap
>>>     (Text.intercalate "\n" . fmap (renderExpression RenderContext'Normal))
>>>     expressionListP
>>> :}

>>> test ""

>>> test "x y z"
x
y
z

>>> test "(a)b c(d)"
a
b
c
d

>>> test "a.\"b\"c"
a.b
c

>>> test "123 ./foo.nix \"abc\" (f { x = y; })"
123
./foo.nix
"abc"
(f { x = y; })

-}
expressionListP :: Parser [Expression]
expressionListP =
  p <?> "expression list"
  where
    p = expressionP'listItem `sepBy` P.spaces

{- | Parser for a single item within an expression list ('expressionListP').
This expression is not a function, a function application, or a let binding.

>>> :{
>>> test = parseTest
>>>   (renderExpression RenderContext'Normal <$> expressionP'listItem)
>>> :}

>>> test "abc def"
abc

>>> test "a.b c"
a.b

>>> test "a.\"b\"c"
a.b

>>> test "(a.b)c"
a.b

>>> test "a.b(c)"
a.b

>>> test "[ a b ]c"
[ a b ]

>>> test "a[ b c ]"
a

>>> test "\"a\"b"
"a"

-}
expressionP'listItem :: Parser Expression
expressionP'listItem =
  p <?> "expression list item"
  where
    p = applyDots
          <$> expressionP'listItem'noDot
          <*> dotsP

{- | Like 'expressionP'listItem', but with the further restriction that the
expression may not be a dot.

>>> :{
>>> test = parseTest
>>>   (renderExpression RenderContext'Normal <$> expressionP'listItem'noDot)
>>> :}

>>> test "a.b c"
a

-}
expressionP'listItem'noDot :: Parser Expression
expressionP'listItem'noDot =
  asum
    [ fmap Expr'Str strExprP
    , fmap Expr'List listLiteralP
    , fmap Expr'Dict dictLiteralP
    , fmap Expr'Id bareIdP
    , expressionP'paren
    ]
    <?> "expression list item without a dot"

{- | Parser for a parenthesized expression, from opening parenthesis to closing
parenthesis. -}
expressionP'paren :: Parser Expression
expressionP'paren =
  braced (P.char '(') (P.char ')') expressionP



--------------------------------------------------------------------------------
--  RenderContext
--------------------------------------------------------------------------------

data RenderContext
  = RenderContext'Normal
  | RenderContext'List
  | RenderContext'Call1
  | RenderContext'Call2
  | RenderContext'Dot1


--------------------------------------------------------------------------------
--  General parsing stuff
--------------------------------------------------------------------------------

sepBy :: Parser a -> Parser b -> Parser [a]
p `sepBy` by =
  (p `sepBy1` by) <|> pure []

sepBy1 :: Parser a -> Parser b -> Parser [a]
p `sepBy1` by =
  (:) <$> p <*> P.many (P.try (by *> p))

braced :: Parser x -> Parser y -> Parser a -> Parser a
braced x y =
  P.between (x *> P.spaces) (P.spaces *> y)
