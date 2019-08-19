{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}

module ChatProcess
  ( chatServer
  , singleMaster
  , nodeMaster
  ) where

import           Control.Concurrent                                 (forkIO)
import           Control.Concurrent.STM
import           Control.Distributed.Process                        (Closure,
                                                                     NodeId,
                                                                     Process,
                                                                     ProcessId)
import qualified Control.Distributed.Process                        as DP
import           Control.Distributed.Process.Backend.SimpleLocalnet
import           Control.Monad
import           Data.List                                          (find)
import qualified Data.Map                                           as Map
import           Text.Printf

import           ChatClient
import           ChatServer

maxTimeout = 100000
registerName = "chatNode"

-- ---- Server Process Helpers ----

nodeMaster ::  Backend
            -> Port
            -> Process ()
nodeMaster backend port = do
    myPid <- DP.getSelfPid
    DP.register registerName myPid
    peers <- DP.liftIO $ findPeers backend maxTimeout
    forM_ peers $ \peer ->
                     DP.whereisRemoteAsync peer registerName
    chatServer $ show port

singleMaster ::  Int
              -> (Port -> Closure (Process ()))
              -> [NodeId]
              -> Process ()
singleMaster stPort closure peers = do
    myPid <- DP.getSelfPid
    pids  <- zipWithM doRun peers [(stPort+1)..]
    let allPids = myPid:pids
    forM_ allPids $ \pid ->
                            DP.send pid $ MsgServers allPids
    chatServer $ show stPort
  where
    doRun peer intPort = run peer (closure $ show intPort)

-- ----  Process Helpers ----

run ::  NodeId
     -> Closure (Process ())
     -> Process ProcessId
run nId closure = do
  DP.say $ printf "spawning on %s" (show nId)
  DP.spawn nId closure

chatServer ::  Port
            -> Process ()
chatServer port = do
    srv <- mkServer []
    _ <- DP.liftIO $ forkIO $ serverIO srv port
    _ <- DP.spawnLocal $ proxy srv
    forever $ DP.expect >>=
      handleRemoteMsg srv

-- | Proxy to server
proxy ::  Server
       -> Process ()
proxy Server {..} = forever $ join $ DP.liftIO $ atomically
                  $ readTChan srvChanProxy

mkServer ::  [ProcessId]
          -> Process Server
mkServer pids = do
    pid <- DP.getSelfPid
    DP.liftIO $ do
      servers      <- newTVarIO pids
      clientMap    <- newTVarIO Map.empty
      newBrdChan   <- newBroadcastTChanIO
      newProxyChan <- newTChanIO
      return Server { srvClients   = clientMap
                    , srvChanBrd   = newBrdChan
                    , srvChanProxy = newProxyChan
                    , srvServers   = servers
                    , srvPid       = pid
                    }

handleRemoteMsg ::  Server
                 -> Message
                 -> Process ()
handleRemoteMsg srv@Server{..} msg = DP.liftIO $ atomically $
  case msg of
    MsgServers pids           -> writeTVar srvServers $ filter (/= srvPid) pids
    MsgSend name m            -> void $ sendToName srv name m
    MsgBroadcast m            -> brdLocal srv m
    MsgKick who by            -> kick srv who by
    MsgClientNew name pid     -> do
      ok <- checkAddClient srv (RC $ RmClient name pid)
      unless ok $ sendRemMsg srv pid $ MsgKick name "SYSTEM"
    MsgClientDiscon name pid  -> do
      clientMap <- readTVar srvClients
      case Map.lookup name clientMap of
        Nothing                                   -> return ()
        Just (RC (RmClient _ pid')) | pid == pid' -> deleteClient srv name
        Just _                                    -> return ()
    MsgNewSrvInfo cltLst pid -> do
      srvPids <- readTVar srvServers
      case find (==pid) srvPids of
        Just    _ -> addSrvClients pid cltLst -- ^ add new clients or kickoff existing
        Nothing   -> do
          modifyTVar srvServers (pid:)
          addSrvClients pid cltLst
    WhereIsReply _ (Just pid) | pid /= srvPid -> do
      cltMap <- readTVar srvClients
      sendRemMsg srv pid $ MsgNewSrvInfo (Map.keys cltMap) srvPid
    WhereIsReply _ _          -> return ()
  where
    checkKnownClients ::  ProcessId
                       -> [ClientName]
                       -> ClientMap
                       -> STM ClientMap
    checkKnownClients newSrvPid newClients cltMap = do
        newMapLst <- zipWithM toNewClientMap (Map.toList cltMap) newClients
        return $ Map.fromList newMapLst
      where
        toNewClientMap (k, LC clt@LcClient{..}) name
          | name == lcName = do
            kick srv name name
            (name,) . RC <$> mkRemoteClient name newSrvPid
          | otherwise            = return (k, LC clt)
        toNewClientMap (k, client) _ =
           return (k, client)

    addSrvClients newSrvPid newCltList  = do
          oldCltMap <- readTVar srvClients
          newCltMap <- checkKnownClients newSrvPid newCltList oldCltMap
          writeTVar srvClients newCltMap
