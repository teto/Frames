{-# LANGUAGE BangPatterns,
             DataKinds,
             FlexibleInstances,
             KindSignatures,
             LambdaCase,
             MultiParamTypeClasses,
             OverloadedStrings,
             QuasiQuotes,
             RecordWildCards,
             ScopedTypeVariables,
             TemplateHaskell,
             TypeOperators #-}
-- | Infer row types from comma-separated values (CSV) data and read
-- that data from files. Template Haskell is used to generate the
-- necessary types so that you can write type safe programs referring
-- to those types.
module Frames.CSV where
import Control.Applicative ((<$>), pure, (<*>))
import Control.Arrow (first)
import Control.Monad (MonadPlus(..))
import Control.Monad.IO.Class
import Data.Char (isAlpha, isAlphaNum, toLower, toUpper)
import Data.Foldable (foldMap)
import Data.Maybe (fromMaybe)
import Data.Monoid ((<>), Monoid(..))
import Data.Proxy
import Data.Readable (Readable(fromText))
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Traversable (sequenceA)
import Data.Vinyl (RElem)
import Data.Vinyl.TypeLevel (RIndex)
import Frames.Col
import Frames.ColumnTypeable
import Frames.ColumnUniverse
import Frames.Rec
import Frames.RecF
import Frames.RecLens
import Language.Haskell.TH
import Language.Haskell.TH.Syntax
import qualified Pipes as P
import System.IO (Handle, hIsEOF, openFile, IOMode(..), withFile)
import Control.Monad (when)
import Data.Maybe (isNothing)
import Control.Monad (void)

type Separator = T.Text

data ParserOptions = ParserOptions { headerOverride :: Maybe [T.Text]
                                   , columnSeparator :: Separator }
  deriving (Eq, Ord, Show)

instance Lift ParserOptions where
  lift (ParserOptions Nothing sep) = [|ParserOptions Nothing $sep'|]
    where sep' = [|T.pack $(stringE $ T.unpack sep)|]
  lift (ParserOptions (Just hs) sep) = [|ParserOptions (Just $hs') $sep'|]
    where sep' = [|T.pack $(stringE $ T.unpack sep)|]
          hs' = [|map T.pack $(listE $  map (stringE . T.unpack) hs)|]

-- | Default 'ParseOptions' get column names from a header line, and
-- use commas to separate columns.
defaultParser :: ParserOptions
defaultParser = ParserOptions Nothing (T.pack defaultSep)

-- | Default separator string.
defaultSep :: String
defaultSep = ","

-- * Parsing

-- | Helper to split a 'T.Text' on commas and strip leading and
-- trailing whitespace from each resulting chunk.
tokenizeRow :: Separator -> T.Text -> [T.Text]
tokenizeRow sep = map T.strip . T.splitOn sep

-- | Infer column types from a prefix (up to 1000 lines) of a CSV
-- file.
prefixInference :: (ColumnTypeable a, Monoid a)
                => T.Text -> Handle -> IO [a]
prefixInference sep h = T.hGetLine h >>= go prefixSize . inferCols
  where prefixSize = 1000 :: Int
        inferCols = map inferType . tokenizeRow sep
        go 0 ts = return ts
        go !n ts =
          hIsEOF h >>= \case
            True -> return ts
            False -> T.hGetLine h >>= go (n - 1) . zipWith (<>) ts . inferCols

-- | Extract column names and inferred types from a CSV file.
readColHeaders :: (ColumnTypeable a, Monoid a)
               => ParserOptions -> FilePath -> IO [(T.Text, a)]
readColHeaders opts f =  withFile f ReadMode $ \h ->
                         zip <$> maybe (tokenizeRow sep <$> T.hGetLine h)
                                       pure
                                       (headerOverride opts)
                             <*> prefixInference sep h
  where sep = columnSeparator opts

-- * Loading Data

-- | Parsing each component of a 'RecF' from a list of text chunks,
-- one chunk per record component.
class ReadRec (rs :: [*]) where
  readRec :: [T.Text] -> RecF Maybe rs

instance ReadRec '[] where
  readRec _ = Nil

instance (Readable t, ReadRec ts) => ReadRec (s :-> t ': ts) where
  readRec [] = frameCons Nothing (readRec [])
  readRec (h:t) = frameCons (fromText h) (readRec t)

-- | Read a 'RecF' from one line of CSV.
readRow :: ReadRec rs => Separator -> T.Text -> RecF Maybe rs
readRow = (readRec .) . tokenizeRow

-- | Produce rows where any given entry can fail to parse.
readTableMaybeOpt :: (MonadIO m, ReadRec rs)
                  => ParserOptions -> FilePath -> P.Producer (RecF Maybe rs) m ()
readTableMaybeOpt opts csvFile =
  do h <- liftIO $ do
            h <- openFile csvFile ReadMode
            when (isNothing $ headerOverride opts) (void $ T.hGetLine h)
            return h
     let sep = columnSeparator opts
         go = liftIO (hIsEOF h) >>= \case
              True -> return ()
              False -> liftIO (readRow sep <$> T.hGetLine h) >>= P.yield >> go
     go
{-# INLINE readTableMaybeOpt #-}

-- | Produce rows where any given entry can fail to parse.
readTableMaybe :: (MonadIO m, ReadRec rs)
               => FilePath -> P.Producer (RecF Maybe rs) m ()
readTableMaybe = readTableMaybeOpt defaultParser
{-# INLINE readTableMaybe #-}

-- | Returns a `MonadPlus` producer of rows for which each column was
-- successfully parsed. This is typically slower than 'readTableOpt'.
readTableOpt' :: forall m rs.
                 (MonadPlus m, MonadIO m, ReadRec rs)
              => ParserOptions -> FilePath -> m (Rec rs)
readTableOpt' opts csvFile =
  do h <- liftIO $ do
            h <- openFile csvFile ReadMode
            when (isNothing $ headerOverride opts) (void $ T.hGetLine h)
            return h
     let sep = columnSeparator opts
         go = liftIO (hIsEOF h) >>= \case
              True -> mzero
              False -> let r = recMaybe . readRow sep <$> T.hGetLine h
                       in liftIO r >>= maybe go (flip mplus go . return)
     go
{-# INLINE readTableOpt' #-}

-- | Returns a `MonadPlus` producer of rows for which each column was
-- successfully parsed. This is typically slower than 'readTable'.
readTable' :: forall m rs. (MonadPlus m, MonadIO m, ReadRec rs)
           => FilePath -> m (Rec rs)
readTable' = readTableOpt' defaultParser
{-# INLINE readTable' #-}

-- | Returns a producer of rows for which each column was successfully
-- parsed.
readTableOpt :: forall m rs.
                (MonadIO m, ReadRec rs)
             => ParserOptions -> FilePath -> P.Producer (Rec rs) m ()
readTableOpt opts csvFile = readTableMaybeOpt opts csvFile P.>-> go
  where go = P.await >>= maybe go (\x -> P.yield x >> go) . recMaybe
{-# INLINE readTableOpt #-}

-- | Returns a producer of rows for which each column was successfully
-- parsed.
readTable :: forall m rs. (MonadIO m, ReadRec rs)
          => FilePath -> P.Producer (Rec rs) m ()
readTable = readTableOpt defaultParser
{-# INLINE readTable #-}

-- * Template Haskell

-- | Generate a column type.
recDec :: ColumnTypeable a => [(T.Text, a)] -> Q Type
recDec = appT [t|Rec|] . go
  where go [] = return PromotedNilT
        go ((n,t):cs) =
          [t|($(litT $ strTyLit (T.unpack n)) :-> $(colType t)) ': $(go cs) |]

-- | Massage a column name from a CSV file into a valid Haskell type
-- identifier.
sanitizeTypeName :: T.Text -> T.Text
sanitizeTypeName = fixupStart . T.concat . T.split (not . valid) . toTitle'
  where valid c = isAlphaNum c || c == '\'' || c == '_'
        toTitle' = foldMap (onHead toUpper) . T.split (not . isAlphaNum)
        onHead f = maybe mempty (uncurry T.cons) . fmap (first f) . T.uncons 
        fixupStart t = case T.uncons t of
                         Nothing -> "Col"
                         Just (c,_) | isAlpha c -> t
                                    | otherwise -> "Col" <> t

-- | Declare a type synonym for a column.
mkColTDec :: TypeQ -> Name -> DecQ
mkColTDec colTypeQ colTName = tySynD colTName [] colTypeQ

-- | Declare a singleton value of the given column type.
mkColPDec :: Name -> TypeQ -> T.Text -> DecsQ
mkColPDec colTName colTy colPName = sequenceA [tySig, val, tySig', val']
  where nm = mkName $ T.unpack colPName
        nm' = mkName $ T.unpack colPName <> "'"
        -- tySig = sigD nm [t|Proxy $(conT colTName)|]
        tySig = sigD nm [t|(Functor f,
                            RElem $(conT colTName) rs (RIndex $(conT colTName) rs))
                         => ($colTy -> f $colTy)
                         -> Rec rs
                         -> f (Rec rs)
                         |]
        tySig' = sigD nm' [t|(Functor f, Functor g,
                             RElem $(conT colTName) rs (RIndex $(conT colTName) rs))
                          => (g $colTy -> f (g $colTy))
                          -> RecF g rs
                          -> f (RecF g rs)
                          |]
        val = valD (varP nm)
                   (normalB [e|rlens (Proxy :: Proxy $(conT colTName))|])
                   []
        val' = valD (varP nm')
                    (normalB [e|rlens' (Proxy :: Proxy $(conT colTName))|])
                    []

-- | For each column, we declare a type synonym for its type, and a
-- Proxy value of that type.
colDec :: ColumnTypeable a => T.Text -> T.Text -> a -> DecsQ
colDec prefix colName colTy = (:) <$> mkColTDec colTypeQ colTName'
                                  <*> mkColPDec colTName' colTyQ colPName
  where colTName = sanitizeTypeName (prefix <> colName)
        colPName = fromMaybe "colDec impossible" $ 
                   fmap (\(c,t) -> T.cons (toLower c) t) (T.uncons colTName)
        colTName' = mkName $ T.unpack colTName
        colTyQ = colType colTy
        colTypeQ = [t|$(litT . strTyLit $ T.unpack colName) :-> $colTyQ|]

-- * Default CSV Parsing

-- | Control how row and named column types are generated.
data RowGen a = RowGen { columnNames    :: [String]
                       -- ^ Use these column names. If empty, expect a
                       -- header row in the data file to provide
                       -- column names.
                       , tablePrefix    :: String
                       -- ^ A common prefix to use for every generated
                       -- declaration.
                       , separator      :: String
                       -- ^ The string that separates the columns on a
                       -- row.
                       , rowTypeName    :: String
                       -- ^ The row type that enumerates all
                       -- columns.
                       , columnUniverse :: Proxy a
                       -- ^ A type that identifies all the types that
                       -- can be used to classify a column. This is
                       -- essentially a type-level list of types. See
                       -- 'colQ'.
                       }

-- | Shorthand for a 'Proxy' value of 'ColumnUniverse' applied to the
-- given type list.
colQ :: Name -> Q Exp
colQ n = [e| (Proxy :: Proxy (ColumnUniverse $(conT n))) |]

-- | A default 'RowGen'. This instructs the type inference engine to
-- get column names from the data file, use the default column
-- separator (a comma), infer column types from the default 'Columns'
-- set of types, and produce a row type with name @Row@.
rowGen :: RowGen Columns
rowGen = RowGen [] "" defaultSep "Row" Proxy

-- | Generate a type for each row of a table. This will be something
-- like @Rec ["x" :-> a, "y" :-> b, "z" :-> c]@.
tableType :: String -> FilePath -> DecsQ
tableType n = tableType' rowGen { rowTypeName = n }

-- | Like 'tableType', but additionally generates a type synonym for
-- each column, and a proxy value of that type. If the CSV file has
-- column names \"foo\", \"bar\", and \"baz\", then this will declare
-- @type Foo = "foo" :-> Int@, for example, @foo = rlens (Proxy :: Proxy
-- Foo)@, and @foo' = rlens' (Proxy :: Proxy Foo)@.
tableTypes :: String -> FilePath -> DecsQ
tableTypes n = tableTypes' rowGen { rowTypeName = n }

-- * Customized Data Set Parsing

-- | Generate a type for a row a table. This will be something like
-- @Rec ["x" :-> a, "y" :-> b, "z" :-> c]@.  Column type synonyms are
-- /not/ generated (see 'tableTypes'').
tableType' :: forall a. (ColumnTypeable a, Monoid a)
           => RowGen a -> FilePath -> DecsQ
tableType' (RowGen {..}) csvFile =
    pure . TySynD (mkName rowTypeName) [] <$>
    (runIO (readColHeaders opts csvFile) >>= recDec')
  where recDec' = recDec :: [(T.Text, a)] -> Q Type
        colNames' | null columnNames = Nothing
                  | otherwise = Just (map T.pack columnNames)
        opts = ParserOptions colNames' (T.pack separator)

-- | Like 'tableType'', but additionally generates a type synonym for
-- each column, and a proxy value of that type. If the CSV file has
-- column names \"foo\", \"bar\", and \"baz\", then this will declare
-- @type Foo = "foo" :-> Int@, for example, @foo = rlens (Proxy ::
-- Proxy Foo)@, and @foo' = rlens' (Proxy :: Proxy Foo)@.
tableTypes' :: forall a. (ColumnTypeable a, Monoid a)
            => RowGen a -> FilePath -> DecsQ
tableTypes' (RowGen {..}) csvFile =
  do headers <- runIO $ readColHeaders opts csvFile
     recTy <- tySynD (mkName rowTypeName) [] (recDec' headers)
     let optsName = case rowTypeName of
                      [] -> error "Row type name shouldn't be empty"
                      h:t -> mkName $ toLower h : t ++ "Parser"
     optsTy <- sigD optsName [t|ParserOptions|]
     optsDec <- valD (varP optsName) (normalB $ lift opts) []
     colDecs <- concat <$> mapM (uncurry $ colDec (T.pack tablePrefix)) headers
     return (recTy : optsTy : optsDec : colDecs)
     -- (:) <$> (tySynD (mkName n) [] (recDec' headers))
     --     <*> (concat <$> mapM (uncurry $ colDec (T.pack prefix)) headers)
  where recDec' = recDec :: [(T.Text, a)] -> Q Type
        colNames' | null columnNames = Nothing
                  | otherwise = Just (map T.pack columnNames)
        opts = ParserOptions colNames' (T.pack separator)
