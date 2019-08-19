module SocketIO
  ( PortStr
  , sockIO ) where

import           Control.Concurrent (forkFinally)
import qualified Control.Exception  as Ex (bracket)
import           Control.Monad      (forever)
import           Network.Socket
import           Text.Printf

-- ---- Type declarations ----

type PortStr = String

-- ---- API ----

sockIO :: PortStr -> (Socket -> IO ()) -> IO ()
sockIO port forkFn = withSocketsDo $ do
    addr <- resolve port
    Ex.bracket (open addr) close loop
  where
    resolve port = do
      let hints = defaultHints { addrFlags      = [AI_PASSIVE]
                               , addrFamily     = AF_INET
                               , addrSocketType = Stream
                               }
      addr:_ <- getAddrInfo (Just hints) (Just "0.0.0.0") (Just port)
      putStrLn $ "Detected: " ++ show addr
      return addr

    open addr = do
      sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      setSocketOption sock ReuseAddr 1
      bind sock (addrAddress addr)
      listen sock 10
      printf "Listening on the port: %s\n" port
      return sock

    loop sock = forever $ do
      (conn, peer) <- accept sock
      putStrLn $ "Connection from: " ++ show peer
      forkFinally (forkFn conn) (\_ -> close conn)
