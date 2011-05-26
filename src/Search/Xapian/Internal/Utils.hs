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

       -- * Debug
     , nullify
     , unnullify
     ) where

import Foreign
import Foreign.C.String
import Blaze.ByteString.Builder as Blaze
import Data.Monoid
import qualified Data.ByteString as BS
import Data.ByteString.Char8 (pack, ByteString, packCString, useAsCString)
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap
import Data.Serialize

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

-- * Document related

newDocumentPtr :: IO DocumentPtr
newDocumentPtr =
 do cx_document_new >>= manage

-- | @addPosting document posting pos@ will index the term @posting@ in
-- the document @document@ at position @pos@.
addPosting' :: DocumentPtr   -- ^ The document to add a posting to
            -> ByteString -- ^ The term to index within the document
            -> Pos           -- ^ The position of the term within the document
            -> IO ()
addPosting' docFPtr term pos =
    withForeignPtr docFPtr $ \docPtr ->
    BS.useAsCString term   $ \cterm ->
    cx_document_add_posting
        docPtr
        cterm
        (fromIntegral pos) -- FIXME
        1 -- FIXME

addTerm' :: DocumentPtr
         -> ByteString
         -> IO ()
addTerm' docFPtr term =
    withForeignPtr docFPtr $ \docPtr ->
    useAsCString term $ \cterm ->
    cx_document_add_term
        docPtr
        cterm
        1 -- FIXME

addValue :: DocumentPtr -> ValueNumber -> Value -> IO ()
addValue docFPtr valno val =
    useAsCString val $ \cval ->
    withForeignPtr docFPtr $ \docPtr ->
    cx_document_add_value docPtr (fromIntegral valno) cval

getDocumentValues :: DocumentPtr -> IO (IntMap Value)
getDocumentValues docFPtr =
    unsafeInterleaveIO $
    withForeignPtr docFPtr $ \docPtr ->
     do b <- manage =<< cx_document_values_begin docPtr
        e <- manage =<< cx_document_values_end docPtr
        fmap IntMap.fromList $ collectValues b e

-- | FIXME wrong implementation
getDocumentTerms :: DocumentPtr -> IO [Term]
getDocumentTerms docFPtr =
    unsafeInterleaveIO $
    withForeignPtr docFPtr $ \docPtr ->
     do b <- manage =<< cx_document_termlist_begin docPtr
        e <- manage =<< cx_document_termlist_end docPtr
        collectTerms b e

  
-- * handling NULL values
-- because cstrings can't contain any NULL value, we have to store 7 bytes of
-- date as 8 bytes of data

_zero = 48 :: Word8
z  = 122 :: Word8
z' = BS.pack [z]
z0 = BS.pack [z,_zero]
zz = BS.pack [z,z]

-- | unnullify maps NULL to z0 and z to zz
unnullify :: ByteString -> ByteString
unnullify = Blaze.toByteString . go
  where
    go bs =
      let (xs,xss) = BS.span (\x -> x /= 0 && x /= z) bs
          replacement = if BS.head xss == 0 then z0
                                            else zz -- this part is still not failsafe
      in if BS.null xss
            then Blaze.fromByteString xs
            else Blaze.fromByteString xs `mappend`
                 Blaze.fromByteString replacement `mappend`
                 go (BS.tail xss)

-- | nullify is the inverse of unnullify
nullify :: ByteString -> Either String ByteString
nullify bs = case go bs of
                  Right builder -> Right $ Blaze.toByteString builder
                  Left errorMsg -> Left errorMsg
  where
    go :: ByteString -> Either String Blaze.Builder
    go bs =
        let (xs,xss) = BS.span (/= z) bs
            replacement = if xss `BS.index` 1 == _zero then 0 :: Word8
                                                       else z -- this part is still not failsafe
        in  if BS.null xss
               then Right $ Blaze.fromByteString xs
               else if BS.length xss == 1
                       then Left "nullify: failed to decode document data"
                       else case go (BS.drop 2 xss) of
                                 Right rest -> Right $ Blaze.fromByteString xs `mappend`
                                                       Blaze.fromStorable replacement `mappend`
                                                       rest
                                 error'     -> error'

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
