{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE RecordWildCards    #-}


module ChatClient
  ( ClientName
  , Msg (..)
  , Message (..)
  , Client (..)
  , ClientMap
  , Server (..)
  , RemoteClient (..)
  , LocalClient (..)
  , mkClient
  , mkRemoteClient
  , clientName
  , broadcast
  , brdRemote
  , brdLocal
  , sendMsg
  , sendRemMsg
  , sendToName
  ) where

import           Control.Concurrent.STM
import           Control.Distributed.Process (Process, ProcessId, send)
import           Data.Binary
import           Data.ByteString             (ByteString)
import           Data.Map                    (Map)
import qualified Data.Map                    as Map
import           Data.Typeable
import           GHC.Generics
import           System.IO                   (Handle)

--  ---- Data Types -----

type ClientName  = ByteString

data Msg = Notice ByteString
         | Tell ClientName ByteString
         | Broadcast ClientName ByteString
         | Command ByteString
         deriving (Typeable, Generic, Show)

instance Binary Msg

data Message = WhereIsReply    String       (Maybe ProcessId)
             | MsgNewSrvInfo   [ClientName] ProcessId
             | MsgServers      [ProcessId]
             | MsgSend         ClientName Msg
             | MsgBroadcast    Msg
             | MsgKick         ClientName ClientName
             | MsgClientNew    ClientName ProcessId
             | MsgClientDiscon ClientName ProcessId
             deriving (Typeable, Generic)

instance Binary Message

--  ---- Server Data ----

type ClientMap = Map ClientName Client
data Server = Server
            { srvClients   :: TVar  ClientMap
            , srvChanProxy :: TChan (Process ())
            , srvChanBrd   :: TChan Msg
            , srvServers   :: TVar  [ProcessId]
            , srvPid       :: ProcessId
            }

-- ---- Server STM Helpers ----

-- | Broadcast message to everyone
broadcast ::  Server
           -> Msg
           -> STM ()
broadcast srv msg = do
    brdRemote srv (MsgBroadcast msg)
    brdLocal srv msg

brdLocal ::  Server
          -> Msg
          -> STM ()
brdLocal Server{..} = writeTChan srvChanBrd

-- | Broadcast message to all connected nodes
brdRemote ::  Server
           -> Message
           -> STM ()
brdRemote srv@Server{..} srvMsg = do
    pids <- readTVar srvServers
    mapM_ sendRem pids
  where sendRem pid = sendRemMsg srv pid srvMsg

-- | Sends message to clinet name
-- returns True on success and False if client do not exists
sendToName ::  Server
            -> ClientName
            -> Msg
            -> STM Bool
sendToName srv@Server{..} name msg = do
    cltMap <- readTVar srvClients
    case Map.lookup name cltMap of
      Nothing  -> return False
      Just clt -> sendMsg srv clt msg >> return True

-- | sends both local and remote messages
sendMsg ::  Server
         -> Client
         -> Msg
         -> STM ()
sendMsg srv (RC c) = sendRemMsg srv (rcHome c)
                   . MsgSend (rcName c)
sendMsg _   (LC c) = sendLocalMsg c


-- | sends remote message to process id
sendRemMsg ::  Server
            -> ProcessId
            -> Message
            -> STM ()
sendRemMsg Server {..} pid = writeTChan srvChanProxy
                           . send pid

-- ---- Client Data ----

data Client      = LC LocalClient
                 | RC RemoteClient

data RemoteClient = RmClient
                  { rcName :: ClientName
                  , rcHome :: ProcessId
                  }

data LocalClient = LcClient
                 { lcName    :: ClientName
                 , lcHandle  :: Handle
                 , lcKicked  :: TVar (Maybe ByteString)
                 , lcChan    :: TChan Msg
                 , lcBrdChan :: TChan Msg
                 }

-- ---- Client API ----

clientName ::  Client
            -> ClientName
clientName (LC c) = lcName c
clientName (RC c) = rcName c

-- ---- Client STM Helpers ----

mkClient ::   Server
          ->  ClientName
          ->  Handle
          ->  TChan Msg
          ->  STM Client
mkClient srv@Server{..} name hdl brdChan = do
    locClt  <- mkLocalClient name hdl brdChan
    brdRemote srv newCltMsg
    return $ LC locClt
  where
    newCltMsg = MsgClientNew name srvPid

mkRemoteClient ::  ClientName
                -> ProcessId
                -> STM RemoteClient
mkRemoteClient name pid = return RmClient { rcName = name
                                          , rcHome = pid
                                          }

mkLocalClient ::  ClientName
               -> Handle
               -> TChan Msg
               -> STM LocalClient
mkLocalClient name handle brdChan = do
  v <- newTVar Nothing
  c <- newTChan
  b <- dupTChan brdChan
  return LcClient { lcName     = name
                  , lcHandle   = handle
                  , lcKicked   = v
                  , lcChan     = c
                  , lcBrdChan  = b
                  }

sendLocalMsg ::  LocalClient
              -> Msg
              -> STM ()
sendLocalMsg LcClient{..} = writeTChan lcChan
