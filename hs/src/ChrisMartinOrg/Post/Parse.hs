{-# LANGUAGE OverloadedStrings #-}

module ChrisMartinOrg.Post.Parse
    ( parsePost
    ) where

import ChrisMartinOrg.Core

import Prelude hiding (lines)

import Control.Applicative ((<|>), many)
import Control.Arrow       (left)
import Control.Lens

import qualified Data.Attoparsec.Text.Lazy as A
import qualified Data.Map.Strict      as Map
import           Data.Maybe           (maybeToList)
import qualified Data.Text            as T
import qualified Data.Text.Lazy       as L

import Data.Validation (AccValidation (..), _Either)

import System.FilePath.Posix ((</>))

parsePost :: FilePath -> L.Text -> Either [T.Text] Post
parsePost dir text = (^. _Either) $ Post dir
    <$> getVal "title"
    <*> eitherVal chron
    <*> getVal "slug"
    <*> AccSuccess thumb
    <*> AccSuccess css
    <*> getVal "abstract"
    <*> AccSuccess body
  where
    (metaText, bodyText) = splitPost text
    meta = Map.fromList $ parseMeta $ L.toStrict metaText
    get key = maybe (Left $ T.append "Missing: " key) Right $ getMaybe key
    getVal = eitherVal . get
    getMaybe key = Map.lookup key meta
    chron = do str <- T.unpack <$> get "date"
               left T.pack (parseChron str)
    css = maybeToList $ (CssSource . (dir </>) . T.unpack) <$> getMaybe "css"
    thumb = ((dir </>) . T.unpack) <$> getMaybe "thumbnail"
    body = parseBody bodyText

eitherVal :: Either a b -> AccValidation [a] b
eitherVal (Left  x) = AccFailure [x]
eitherVal (Right x) = AccSuccess  x

-- | Splits a post file in two parts: its metadata, and its body. The first line in
-- the file is discarded and used as the delimiter between the metadata and the body.
-- In other words, the metadata must be surrounded by a pair of identical lines.
--
-- >>> splitPost "---\nabc\ndef\n---\nghi\njkl"
-- ("abc\ndef","ghi\njkl")
splitPost :: L.Text -> (L.Text, L.Text)
splitPost text = splitOn2L sep otherLines where
    (firstLine, otherLines) = splitOn2L "\n" text
    sep = L.concat ["\n", firstLine, "\n"]

-- |
-- >>> parseMeta "abc: def"
-- [("abc","def")]
--
-- >>> :{
--   parseMeta $ Text.unlines [ "one:two"
--                            , "three: four"
--                            , "five:  six"
--                            , "       seven" ]
-- :}
-- [("one","two"),("three","four"),("five","six\nseven")]
parseMeta :: T.Text -> [(T.Text, T.Text)]
parseMeta meta = parseMetaKV <$> lineGroups where
    lineGroups = groupByStart ((/= " ") . T.take 1) $ T.lines meta

-- |
-- >>> parseMetaKV ["abc: def"]
-- ("abc","def")
--
-- >>> :{
--   parseMetaKV [ "abc:  def"
--               , "       ghi" ]
-- :}
-- ("abc","def\n ghi")
parseMetaKV :: [T.Text] -> (T.Text, T.Text)
parseMetaKV lines = (T.strip k, T.intercalate "\n" vLines) where
    (k, v1) = splitOn2T ":" $ head lines
    startCol = T.length k + 1 + T.length (T.takeWhile (== ' ') v1)
    vLines = T.drop startCol <$> lines

-- |
-- >>> groupByStart (== '-') "one-two-three"
-- ["one","-two","-three"]
groupByStart :: (a -> Bool) -> [a] -> [[a]]
groupByStart isStart = foldr f [] where
    f x acc = case acc of
        [] -> [[x]]
        groups@((y:_):_) | isStart y -> [x] : groups
        (group:otherGroups) -> (x:group) : otherGroups

-- Like breakOn, but does not include the pattern in the second piece. Or like
-- splitOn, but only performing a single split rather than arbitrarily many.
splitOn2L :: L.Text -> L.Text -> (L.Text, L.Text)
splitOn2L pat src = case L.breakOn pat src of
    (x, y) -> (x, L.drop (L.length pat) y)

splitOn2T :: T.Text -> T.Text -> (T.Text, T.Text)
splitOn2T pat src = case T.breakOn pat src of
    (x, y) -> (x, T.drop (T.length pat) y)

parseBody :: L.Text -> PostBody
parseBody t = case A.parse bodyParser t of
    A.Done i r -> r

bodyParser :: A.Parser PostBody
bodyParser = PostBodyList <$> many (asset <|> stuff)
    where
    asset :: A.Parser PostBody
    asset = (PostBodyAsset . T.unpack) <$> (open *> value <* close)
        where
        open = A.string (T.pack "${")
        value = A.takeWhile (/= '}')
        close = A.string (T.pack "}")
    stuff :: A.Parser PostBody
    stuff = PostBodyText . L.fromStrict <$>
        (A.string (T.pack "$") <|> A.takeWhile1 (/= '$'))