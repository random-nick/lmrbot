module Main where

import Control.Monad.Random ()
import Control.Monad.Trans.Maybe
import Data.BotConfig
import Data.ByteString.Char8 (ByteString)
import Data.Maybe
import Data.Monoid
import Data.Response
import Network.IRC
import Pipes
import Pipes.Network
import qualified Pipes.Prelude as P

import Commands.Admin
import Commands.Quote
import Commands.Interject

import Options.Applicative

data Options = Options
    { configPath :: Maybe FilePath
    }

optParser :: Parser Options
optParser = Options 
    <$> optional 
        (strOption ( long "config" 
                  <> metavar "FILE" 
                  <> help "Config File Location" ))

optInfo :: ParserInfo Options
optInfo = info (helper <*> optParser)
    ( fullDesc
   <> progDesc "An IRC Bot"
   <> header "lmrbot - A spambot" )

response :: Monad m => [Response m] -> Pipe Message ByteString m ()
response rsps = P.mapM go >-> filterJust >-> P.map encode
    where go m = listToMaybe . catMaybes <$> mapM (`respond` m) rsps

bootstrap :: MonadIO m 
          => BotConfig 
          -> Producer ByteString m () 
          -> Consumer ByteString m () 
          -> Effect m ()
bootstrap conf up down = do
    up >-> P.take 2 >-> inbound
    register conf >-> P.map encode >-> P.tee outbound >-> down

    -- wait for and respond to initial ping
    up >-> P.tee inbound >-> parseIRC >-> P.dropWhile (not . isPing) 
       >-> P.take 1 >-> response [ pingR ] >-> P.tee outbound >-> down

    -- drain until nickserv notice
    up >-> P.tee inbound >-> parseIRC >-> P.dropWhile (not . isNSNotice) 
       >-> P.take 1 >-> P.drain

    -- do nickserv auth
    auth conf >-> P.map encode >-> P.tee outbound >-> down
    
    -- join
    joins conf >-> P.map encode >-> P.tee outbound >-> down

main :: IO ()
main = do
    opts <- execParser optInfo
    conf <- fmap (fromMaybe defaultConfig) . runMaybeT $ do
                p <- MaybeT . return $ configPath opts
                MaybeT $ readConfig p
    print conf
    h <- network conf
    let up   = fromHandleLine h
        down = toHandleLine h

    runEffect $ bootstrap conf up down 

    cooldown <- emptyCooldown
    comms' <- sequence (comms conf cooldown)

    -- bot loop
    runEffect $ 
        up >-> P.tee inbound >-> parseIRC >-> response comms'
           >-> P.tee outbound >-> down

    where comms c ulim = 
              [ return pingR
              , return ctcpVersion
              , return $ joinCmd c
              , return $ leaveCmd c
              , userLimit' c ulim rms
              , userLimit' c ulim linus
              , userLimit' c ulim theo 
              , userLimit' c ulim catv
              , rateLimit c interject
              ]
