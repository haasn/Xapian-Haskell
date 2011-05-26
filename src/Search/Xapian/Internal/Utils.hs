module Search.Xapian.Internal.Utils
     ( -- * General
       collect
     , collectTerms
     , collectDocIds
     , collectValues

       -- * Stemmer related
     , createStemmer
     , stemWord
     , indexToDocument
     ) where

import Foreign
import Foreign.C.String
import Blaze.ByteString.Builder as Blaze
import Data.Monoid
import qualified Data.ByteString as BS
import Data.ByteString.Char8 (pack, ByteString, packCString, useAsCString)
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap

import System.IO.Unsafe (unsafeInterleaveIO)

import Search.Xapian.Internal.Types
import Search.Xapian.Internal.FFI

-- * General

-- | @collect@ returns objects using a triple of functions over iterators
-- @(finished, next, get)@ and two pointers @pos@ and @end@ where
-- 
-- @pos@ points to the current iterator position
-- 
-- @end@ denotes the end of the iterator
--
-- @finished@ checks whether there are elements
-- left in the iterator
--
-- @next@ moves the @pos@ to the next element
-- 
-- @get@ converts the pointer to some meaningful 'object' performing an
-- effectful computation
collect :: (Ptr a -> IO ()) -- next
        -> (Ptr a -> IO b)  -- get
        -> (Ptr a -> Ptr a -> IO CBool) -- finished?
        -> ForeignPtr a -- current position
        -> ForeignPtr a -- end
        -> IO [b]
collect next' get' finished' pos' end' =
    withForeignPtr pos' $ \posPtr ->
    withForeignPtr end' $ \endPtr ->
    collect' next' get' finished' posPtr endPtr
  where
    collect' next get finished pos end =
     do exit <- finished pos end
        if exit /= 0
           then do return []
           else do element <- get pos
                   _ <- next pos
                   rest <- collect' next get finished pos end
                   return (element : rest)

collectPositions :: ForeignPtr CPositionIterator
                 -> ForeignPtr CPositionIterator
                 -> IO [Pos]
collectPositions = collect cx_positioniterator_next
                           cx_positioniterator_get
                           cx_positioniterator_is_end

collectTerms :: ForeignPtr CTermIterator -- current position
             -> ForeignPtr CTermIterator -- end
             -> IO [Term]
collectTerms b e = collect cx_termiterator_next getter cx_termiterator_is_end b e
  where
    getter ptr =
     do term <- BS.packCString =<< cx_termiterator_get ptr
        positions_len <- cx_termiterator_positionlist_count ptr
        b_pos <- manage =<< cx_termiterator_positionlist_begin ptr
        e_pos <- manage =<< cx_termiterator_positionlist_end ptr
        if positions_len <= 0
           then do return $ Term term []
           else do positions <- unsafeInterleaveIO $
                       collectPositions b_pos e_pos
                   return $ Term term positions

collectDocIds :: ForeignPtr CMSetIterator
              -> ForeignPtr CMSetIterator
              -> IO [DocumentId]
collectDocIds = collect cx_msetiterator_next
                        (fmap DocId . cx_msetiterator_get)
                        cx_msetiterator_is_end

collectValues :: ForeignPtr CValueIterator
              -> ForeignPtr CValueIterator
              -> IO [(Int, Value)]
collectValues = collect cx_valueiterator_next
                        getter
                        cx_valueiterator_is_end
  where
    getter ptr = do value <- BS.packCString =<< cx_valueiterator_get ptr
                    valno <- cx_valueiterator_get_valueno ptr
                    return (fromIntegral valno, value)

-- | @indexToDocument stemmer document text@ adds stemmed posting terms derived from
-- @text@ using the stemming algorith @stemmer@ to @doc@
indexToDocument
    :: Ptr CDocument  -- ^ The document to add terms to
    -> Maybe Stemmer  -- ^ The stemming algorithm to use
    -> ByteString     -- ^ The text to stem and index
    -> IO ()
indexToDocument docPtr mStemmer text =
 do termgenFPtr <- manage =<< cx_termgenerator_new
    withForeignPtr termgenFPtr $ \termgen ->
     do maybe (return ())
              (\stemmer ->
               do stemFPtr <- createStemmer stemmer
                  withForeignPtr stemFPtr $ \stemPtr ->
                      cx_termgenerator_set_stemmer termgen stemPtr)
              mStemmer
        useAsCString text $ \ctext ->
         do prefix <- newCString ""
            let weight = 1
            cx_termgenerator_set_document termgen docPtr
            cx_termgenerator_index_text termgen ctext weight prefix

stemWord :: StemPtr -> ByteString -> IO ByteString
stemWord stemFPtr word =
    withForeignPtr stemFPtr $ \stemPtr ->
    useAsCString word $ \cword ->
    cx_stem_word stemPtr cword >>= packCString


createStemmer :: Stemmer -> IO StemPtr
createStemmer stemmer =
    let lang = case stemmer of
                    Danish  -> "danish"
                    Dutch   -> "dutch"
                    DutchKraaijPohlmann -> "kraaij_pohlmann"
                    English -> "english"
                    EnglishLovins -> "lovins"
                    EnglishPorter -> "porter"
                    Finnish -> "finnish"
                    French  -> "french"
                    German  -> "german"
                    German2 -> "german2"
                    Hungarian  -> "hungarian"
                    Italian -> "italian"
                    Norwegian  -> "norwegian"
                    Portuguese -> "portuguese"
                    Romanian -> "romanian"
                    Russian -> "russian"
                    Spanish -> "spanish"
                    Swedish -> "swedish"
                    Turkish -> "turkish"
    in useAsCString (pack lang) $ \clang ->
        do cx_stem_new_with_language clang >>= manage
