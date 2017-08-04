{-# LANGUAGE DeriveFunctor        #-}
{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE GADTs                #-}
{-# LANGUAGE KindSignatures       #-}
{-# LANGUAGE LambdaCase           #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE RankNTypes           #-}
{-# LANGUAGE RecordWildCards      #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE StandaloneDeriving   #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE TupleSections        #-}
{-# LANGUAGE TypeApplications     #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE TypeInType           #-}
{-# LANGUAGE TypeOperators        #-}
{-# LANGUAGE ViewPatterns         #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Authenticator (
    Mode(..)
  , Sing(SHOTP, STOTP)
  , SMode, HOTPSym0, TOTPSym0
  , HashAlgo(..)
  , parseAlgo
  , Secret(..)
  , ModeState(..)
  , Store(..)
  , _Store
  , hotp
  , totp
  , totp_
  , otp
  , someotp
  , someSecret
  , storeSecrets
  , describeSecret
  , secretURI
  , parseSecretURI
  ) where

import           Control.Applicative
import           Control.Monad
import           Crypto.Hash.Algorithms
import           Data.Bitraversable
import           Data.Char
import           Data.Dependent.Sum
import           Data.Kind
import           Data.Maybe
import           Data.Semigroup
import           Data.Singletons
import           Data.Singletons.TH
import           Data.Time.Clock
import           Data.Type.Combinator
import           Data.Type.Conjunction
import           Data.Word
import           GHC.Generics              (Generic)
import           Text.Read                 (readMaybe)
import           Type.Class.Higher
import           Type.Class.Witness
import qualified Data.Base32String.Default as B32
import qualified Data.Binary               as B
import qualified Data.ByteString           as BS
import qualified Data.Map                  as M
import qualified Data.OTP                  as OTP
import qualified Data.Text                 as T
import qualified Network.URI.Encode        as U
import qualified Text.Trifecta             as P

$(singletons [d|
  data Mode = HOTP | TOTP
    deriving (Generic, Show)
  |])

instance B.Binary Mode

data family ModeState :: Mode -> Type
data instance ModeState 'HOTP = HOTPState Word64
  deriving (Generic, Show)
data instance ModeState 'TOTP = TOTPState
  deriving (Generic, Show)

instance B.Binary (ModeState 'HOTP)
instance B.Binary (ModeState 'TOTP)

modeStateBinary :: Sing m -> Wit1 B.Binary (ModeState m)
modeStateBinary = \case
    SHOTP -> Wit1
    STOTP -> Wit1

data HashAlgo = HASHA1 | HASHA256 | HASHA512
  deriving (Generic, Show)

instance B.Binary HashAlgo

hashAlgo :: HashAlgo -> SomeC HashAlgorithm I
hashAlgo HASHA1   = SomeC (I SHA1  )
hashAlgo HASHA256 = SomeC (I SHA256)
hashAlgo HASHA512 = SomeC (I SHA512)

parseAlgo :: String -> Maybe HashAlgo
parseAlgo = (`lookup` algos) . map toLower . unwords . words
  where
    algos = [("sha1", HASHA1)
            ,("sha256", HASHA256)
            ,("sha512", HASHA512)
            ]

-- TODO: add period?
data Secret :: Mode -> Type where
    Sec :: { secAccount :: T.Text
           , secIssuer  :: Maybe T.Text
           , secAlgo    :: HashAlgo
           , secDigits  :: Word
           , secKey     :: BS.ByteString
           }
        -> Secret m
  deriving (Generic, Show)

instance B.Binary (Secret m)

describeSecret :: Secret m -> T.Text
describeSecret s = secAccount s <> case secIssuer s of
                                     Nothing -> ""
                                     Just i  -> " / " <> i

instance B.Binary (DSum Sing (Secret :&: ModeState)) where
    get = do
      m <- B.get
      withSomeSing m $ \s -> modeStateBinary s // do
        sc <- B.get
        ms <- B.get
        return $ s :=> sc :&: ms
    put = \case
      s :=> sc :&: ms -> modeStateBinary s // do
        B.put $ fromSing s
        B.put sc
        B.put ms

data Store = Store { storeList :: [DSum Sing (Secret :&: ModeState)] }
  deriving Generic

instance B.Binary Store

hotp :: Secret 'HOTP -> ModeState 'HOTP -> (Word32, ModeState 'HOTP)
hotp Sec{..} (HOTPState i) = (p, HOTPState (i + 1))
  where
    p = hashAlgo secAlgo >>~ \(I a) -> OTP.hotp a secKey i secDigits

totp_ :: Secret 'TOTP -> UTCTime -> Word32
totp_ Sec{..} t = hashAlgo secAlgo >>~ \(I a) ->
    OTP.totp a secKey (30 `addUTCTime` t) 30 secDigits

totp :: Secret 'TOTP -> IO Word32
totp s = totp_ s <$> getCurrentTime

otp :: forall m. SingI m => Secret m -> ModeState m -> IO (Word32, ModeState m)
otp = case sing @_ @m of
    SHOTP -> curry $ return . uncurry hotp
    STOTP -> curry $ bitraverse totp return

someotp :: DSum Sing (Secret :&: ModeState) -> IO (Word32, DSum Sing (Secret :&: ModeState))
someotp = getComp . someSecret (\s -> Comp . otp s)

someSecret
    :: Functor f
    => (forall m. SingI m => Secret m -> ModeState m -> f (ModeState m))
    -> DSum Sing (Secret :&: ModeState)
    -> f (DSum Sing (Secret :&: ModeState))
someSecret f = \case
    s :=> (sc :&: ms) -> withSingI s $ ((s :=>) . (sc :&:)) <$> f sc ms

deriving instance (Functor f, Functor g) => Functor (f :.: g)

storeSecrets
    :: Applicative f
    => (forall m. SingI m => Secret m -> ModeState m -> f (ModeState m))
    -> Store
    -> f Store
storeSecrets f = (_Store . traverse) (someSecret f)

_Store
    :: Functor f
    => ([DSum Sing (Secret :&: ModeState)] -> f [DSum Sing (Secret :&: ModeState)])
    -> Store
    -> f Store
_Store f s = Store <$> f (storeList s)

secretURI :: P.Parser (DSum Sing (Secret :&: ModeState))
secretURI = do
    _ <- P.string "otpauth://"
    m <- otpMode
    _ <- P.char '/'
    (a,i) <- otpLabel
    ps <- M.fromList <$> param `P.sepBy` P.char '&'
    sec <- case M.lookup "secret" ps of
      Nothing -> fail "Required parameter 'secret' not present"
      Just (T.concat.T.words->s)
        | T.all (`elem` b32s) (T.map toUpper s) -> return $ B32.fromText s
        | otherwise -> fail $ "Not a valid base-32 string: " ++ T.unpack s
    let dig = fromMaybe 6 $ do
          d <- M.lookup "digits" ps
          readMaybe @Word $ T.unpack d
        i' = i <|> M.lookup "issuer" ps
        alg = fromMaybe HASHA1 $ do
          al <- M.lookup "algorithm" ps
          parseAlgo . T.unpack . T.map toLower $ al
        secr :: forall m. Secret m
        secr = Sec a i' alg dig (B32.toBytes sec)

    withSomeSing m $ \case
      SHOTP -> case M.lookup "counter" ps of
          Nothing -> fail "Paramater 'counter' required for hotp mode"
          Just (T.unpack->c)  -> case readMaybe c of
            Nothing -> fail $ "Could not parse 'counter' parameter: " ++ c
            Just c' -> return $ SHOTP :=> secr :&: HOTPState c'
      STOTP -> return $ STOTP :=> secr :&: TOTPState
  where
    b32s = ['A' .. 'Z'] ++ ['2'..'7']
    otpMode :: P.Parser Mode
    otpMode = HOTP <$ P.string "hotp"
          <|> HOTP <$ P.string "HOTP"
          <|> TOTP <$ P.string "totp"
          <|> TOTP <$ P.string "TOTP"
    otpLabel :: P.Parser (T.Text, Maybe T.Text)
    otpLabel = do
      x <- P.some (P.try (mfilter (/= ':') uriChar))
      rest <- Just <$> (colon
                     *> P.many (P.try uriSpace)
                     *> P.some (P.try uriChar)
                     <* P.char '?'
                       )
          <|> Nothing <$ P.char '?'
      return $ case rest of
        Nothing -> (T.pack . U.decode $ x, Nothing)
        Just y  -> (T.pack . U.decode $ y, Just . T.pack . U.decode $ x)
    param :: P.Parser (T.Text, T.Text)
    param = do
      k <- T.map toLower . T.pack <$> P.some (P.try uriChar)
      _ <- P.char '='
      v <- T.pack <$> P.some (P.try uriChar)
      return (k, v)
    uriChar = P.satisfy U.isAllowed
          <|> P.char '@'
          <|> (do x <- U.decode <$> sequence [P.char '%', P.hexDigit, P.hexDigit]
                  case x of
                    [y] -> return y
                    _   -> fail "Invalid URI escape code"
              )
    colon    = void (P.char ':') <|> void (P.string "%3A")
    uriSpace = void P.space      <|> void (P.string "%20")

parseSecretURI
    :: String
    -> Either String (DSum Sing (Secret :&: ModeState))
parseSecretURI s = case P.parseString secretURI mempty s of
    P.Success r -> Right r
    P.Failure e -> Left (show e)
