{-# LANGUAGE NoImplicitPrelude #-}

module Bricks.Internal.Seq

  ( module Data.Sequence

  , concat
  , intersperse
  , map
  , minimum
  , toList

  ) where

-- Containers
import Data.Sequence

-- Base
import           Data.Foldable (Foldable, fold, toList)
import           Data.Functor  (fmap)
import qualified Data.List     as List
import           Data.Maybe    (Maybe (..))
import           Data.Ord      (Ord)

intersperse :: a -> Seq a -> Seq a
intersperse x xs =
  fromList (List.intersperse x (toList xs))

concat :: Foldable f => f (Seq a) -> Seq a
concat = fold

minimum :: Ord a => Seq a -> Maybe a
minimum xs =
  if null xs then Nothing else Just (List.minimum (toList xs))

map :: (a -> b) -> Seq a -> Seq b
map = fmap