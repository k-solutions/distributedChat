{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}

module Ping
  ( pingServer
  , master
  ) where

import           Control.Distributed.Process                        hiding
                                                                     (Message)
import           Control.Distributed.Process.Backend.SimpleLocalnet (Backend (..),
                                                                     terminateAllSlaves)
import           Control.Monad                                      (forM,
                                                                     forM_)
import           Data.Binary
import           Data.Typeable
import           GHC.Generics
import           Text.Printf

newtype Message = Ping (SendPort ProcessId)
                 deriving (Typeable, Generic)

instance Binary Message

pingServer :: Process ()
pingServer = do
    Ping chan <- expect
    say $ printf "ping recived from %s" (show chan)
    myPid     <- getSelfPid
    sendChan chan myPid

master :: Closure (Process ()) -> Backend -> Process ()
master remoteExec backend = do
    myPid  <- getSelfPid
    register "simple" myPid

    peers  <- liftIO $ findPeers backend 1000000
    ps     <- forM peers $ \nId -> do
      say $ printf "spawning on %s" (show nId)
      spawn nId remoteExec

    mapM_ monitor ps

    ports <- forM ps $ \pid -> do
      say $ printf "pinging %s" (show pid)
      (sendPort, recvPort) <- newChan
      send pid (Ping sendPort)
      return recvPort
    mstChan <- mergePortsRR ports
    waitForPongs mstChan ps

    terminateAllSlaves backend
    terminate

waitForPongs ::  ReceivePort ProcessId
              -> [ProcessId]
              -> Process ()
waitForPongs _ []    = return ()
waitForPongs chan ps = do
    pid <- receiveChan chan
    waitForPongs chan $ filter (/=pid) ps
