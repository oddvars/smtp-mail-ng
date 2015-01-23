{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Network.Mail.SMTP.SMTP (

    SMTP

  , smtp

  , command
  , expect
  , expectCode

  , SMTPContext
  , smtpContext

  , getSMTPServerHostName
  , getSMTPClientHostName

  , startTLS

  , SMTPError(..)

  ) where

import Control.Exception
import Control.Monad
import Control.Applicative
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Control.Monad.Trans.Except
import Control.Monad.Trans.State

import Network
import Network.BSD
import Network.Mail.SMTP.Types
import Network.Mail.SMTP.ReplyLine
import Network.Mail.SMTP.SMTPRaw
import Network.Mail.SMTP.SMTPParameters

-- STARTTLS support demands some TLS- and X.509-related definitions.
import Network.TLS
import Network.TLS.Extra.Cipher (ciphersuite_all)
import System.X509 (getSystemCertificateStore)
import Data.X509.CertificateStore (CertificateStore)
import Data.ByteString.Char8 (pack)
import qualified Data.ByteString.Lazy as BL
import Crypto.Random

import System.IO

data SMTPError
  = UnexpectedResponse
  | ConnectionFailure
  | EncryptionError
  | UnknownError
  deriving (Show, Eq)

data SMTPContext = SMTPContext {
    smtpRaw :: SMTPRaw
  , smtpServerHostName :: HostName
  , smtpClientHostName :: HostName
  , smtpDebug :: String -> IO ()
  }

-- | Access the Handle datatype buried beneath the SMTP abstraction.
--   Use with care!
getSMTPHandle :: SMTPContext -> Handle
getSMTPHandle = smtpHandle . smtpRaw

getSMTPServerHostName :: SMTPContext -> HostName
getSMTPServerHostName = smtpServerHostName

getSMTPClientHostName :: SMTPContext -> HostName
getSMTPClientHostName = smtpClientHostName

-- | We define a little SMTP DSL: it can do effects, things can go wrong, and
--   it carried immutable state.
newtype SMTP a = SMTP {
    runSMTP :: ExceptT SMTPError (StateT SMTPContext IO) a
  } deriving (Functor, Applicative, Monad, MonadIO)

-- | Run an expression in the SMTP monad.
--   Should be exception safe, but I am not confident in this.
smtp :: SMTPParameters -> SMTP a -> IO (Either SMTPError a)
smtp smtpParameters smtpValue = do
  smtpContext <- makeSMTPContext smtpParameters
  case smtpContext of
    Left err -> return $ Left err
    Right smtpContext -> do
      x <- evalStateT (runExceptT (runSMTP smtpValue)) smtpContext
      closeSMTPContext smtpContext
      return x

makeSMTPContext :: SMTPParameters -> IO (Either SMTPError SMTPContext)
makeSMTPContext smtpParameters = do
    clientHostname <- getHostName
    result <- liftIO $ try (smtpConnect serverHostname (fromIntegral port))
    return $ case result :: Either SomeException (SMTPRaw, Maybe Greeting) of
      Left err -> Left ConnectionFailure
      Right (smtpRaw, _) -> Right $ SMTPContext smtpRaw serverHostname clientHostname debug
  where
    serverHostname = smtpHost smtpParameters
    port = smtpPort smtpParameters
    debug = if smtpVerbose smtpParameters
            then print
            else const (return ())

closeSMTPContext :: SMTPContext -> IO ()
closeSMTPContext smtpContext = do
  hClose (smtpHandle (smtpRaw smtpContext))

-- | Send a command wait for the reply.
command :: Command -> SMTP [ReplyLine]
command cmd = SMTP $ do
  ctxt <- lift get
  liftIO $ (smtpDebug ctxt ("Send command: " ++ show cmd))
  result <- liftIO $ try ((smtpSendCommandAndWait (smtpRaw ctxt) cmd))
  liftIO $ (smtpDebug ctxt ("Receive response: " ++ show result))
  case result :: Either SomeException (Maybe [ReplyLine]) of
    Left err -> throwE UnknownError
    Right x -> case x of
      Just y -> return y
      Nothing -> throwE UnknownError

expect :: [ReplyLine] -> ([ReplyLine] -> Maybe SMTPError) -> SMTP ()
expect reply ok = SMTP $ do
  case ok reply of
    Just err -> throwE err
    Nothing -> return ()

expectCode :: [ReplyLine] -> ReplyCode -> SMTP ()
expectCode reply code = expect reply hasCode
  where
    hasCode [] = Just UnexpectedResponse
    hasCode (reply : _) =
      if replyCode reply == code
      then Nothing
      else Just UnexpectedResponse

-- | Grab the SMTPContext.
smtpContext :: SMTP SMTPContext
smtpContext = SMTP $ lift get

-- | Try to get TLS going on an SMTP connection.
startTLS :: SMTP ()
startTLS = do
  context <- tlsContext
  reply <- command STARTTLS
  expectCode reply 220
  tlsUpgrade context
  ctxt <- smtpContext
  reply <- command (EHLO (pack $ getSMTPClientHostName ctxt))
  expectCode reply 250

tlsContext :: SMTP Context
tlsContext = SMTP $ do
  ctxt <- lift get
  tlsContext <- liftIO $ try (makeTLSContext (getSMTPHandle ctxt) (getSMTPServerHostName ctxt))
  case tlsContext :: Either SomeException Context of
    Left err -> throwE EncryptionError
    Right context -> return context

tlsUpgrade :: Context -> SMTP ()
tlsUpgrade context = SMTP $ do
  result <- liftIO $ try (handshake context)
  case result :: Either SomeException () of
    Left err -> throwE EncryptionError
    Right () -> do
      -- Now that we have upgraded, we must change the means by which we push
      -- and pull data to and from the pipe; we must use the TLS library's
      -- sendData and recvData
      let push = sendData context . BL.fromStrict
      let pull = recvData context
      let close = contextClose context
      lift $ modify (\ctx ->
          ctx { smtpRaw = SMTPRaw push pull close (smtpHandle (smtpRaw ctx)) }
        )

-- | Get a TLS context on a given Handle against a given HostName.
--   We choose a big cipher suite, the SystemRNG, and the system certificate
--   store. Hopefully this will work most of the time.
--   This action may throw an exception. We are careful to handle it and
--   coerce it into a first-class value.
makeTLSContext :: Handle -> HostName -> IO Context
makeTLSContext handle hostname = do
  -- Grab a random number generator.
  rng <- (createEntropyPool >>= return . cprgCreate) :: IO SystemRNG
  -- Find the certificate store. No error reporting if we can't find it; you'll
  -- just (probably) get an error later when the TLS handshake fails due to
  -- an unknown CA.
  certStore <- getSystemCertificateStore
  let params = tlsClientParams hostname certStore
  contextNew handle params rng

-- | ClientParams are a slight variation on the default: we throw in a given
--   certificate store and widen the supported ciphers.
tlsClientParams :: HostName -> CertificateStore -> ClientParams
tlsClientParams hostname certStore = dflt {
      clientSupported = supported
    , clientShared = shared
    }
  where
    dflt = defaultParamsClient hostname ""
    shared = (clientShared dflt) { sharedCAStore = certStore }
    supported = (clientSupported dflt) { supportedCiphers = ciphersuite_all }
