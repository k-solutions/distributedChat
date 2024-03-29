{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module ChatServer
  ( serverIO
  , Port
  , deleteClient
  , removeClient
  , runClient
  , checkAddClient
  , kick
  , tell
  ) where

import           Control.Concurrent.Async (race)
import           Control.Concurrent.STM
import           Control.Exception        (finally, mask)
import           Control.Monad            (forever, join, when)
import           Data.ByteString          (ByteString)
import qualified Data.ByteString.Char8    as BC
import qualified Data.Map                 as Map
import qualified Network.Simple.TCP       as NetS
import           Network.Socket           (socketToHandle)
import           System.IO

import           ChatClient
-- import           SocketIO

type Port = String

-- ---- Server IO Heleprs ----

serverIO ::  Server
          -> Port
          -> IO ()
serverIO srv port =
   -- sockIO port (talkTo srv)
   NetS.serve "0.0.0.0" port (talkTo srv)
  where
    talkTo server (conn, remAddr) = do
      putStrLn $ "Connection established from " ++ show remAddr
      hdl    <- socketToHandle conn ReadWriteMode
      forever $ talk hdl server

talk ::  Handle
      -> Server
      -> IO ()
talk hdl server = do
    hSetNewlineMode hdl universalNewlineMode      -- ^ Swallow carriage returns sent
    hSetBuffering hdl LineBuffering
    readName
  where
    readName = do
      BC.hPutStrLn  hdl "Enter name: "
      name <- BC.hGetLine hdl
      if BC.null name
        then do
          BC.hPutStrLn hdl "Please enter non empty name: "
          readName
        else mask $ \restore -> do
          mbClient <- addClient server name hdl
          case mbClient of
            Nothing     -> do
              BC.hPutStrLn hdl $ BC.concat ["Username " , name, " is in use, try with other, please."]
              readName
            Just client ->
              restore (runClient server client)
                  `finally` removeClient server name

-- ---- Client IO Helpers ----

handleMsg ::  Server
           -> LocalClient
           -> Msg
           -> IO Bool
handleMsg server LcClient{..} msg =
    case msg of
      Notice bsMsg         -> printBS $ BC.concat ["*** ", bsMsg]
      Tell from bsMsg      -> printBS $ BC.concat ["*", from, "* ", bsMsg]
      Broadcast from bsMsg -> printBS $ BC.concat ["<", from, "> ", bsMsg]
      Command bsCmd        -> handleCmd $ BC.words bsCmd
  where
    printBS bs = BC.hPutStrLn lcHandle bs >> return True

    handleCmd ::  [ByteString]
               -> IO Bool
    handleCmd  ["/quit"]            = return False
    handleCmd  ["/kick", who]       = do
                atomically $ kick server lcName who
                return True
    handleCmd  ("/tell":who:what)   = do
                atomically $ tell server who (Tell lcName $ BC.unwords what)
                return True
    handleCmd bsLst                 = broadcastOrBadCmd bsLst
      where
        broadcastOrBadCmd :: [ByteString] -> IO Bool
        broadcastOrBadCmd []  = return True
        broadcastOrBadCmd bs@(hd:_)
          | BC.head hd == '/' =
            printBS $ BC.concat ["Unrecognised command: ", hd]
          | otherwise                  = do
            atomically $ broadcast server (Broadcast lcName $ BC.unwords bs)
            return True

runClient ::  Server
           -> Client
           -> IO ()
runClient srv@Server{..} (LC clt@LcClient{..}) = do
    _ <- race serverTrd receiveTrd
    return ()
  where
    receiveTrd = forever $ do
      msg <- BC.hGetLine lcHandle
      atomically $ sendMsg srv (LC clt) (Command msg)

    serverTrd = join $ atomically $ do
      k <- readTVar lcKicked
      case k of
        Just reason ->
          return $ BC.hPutStrLn lcHandle $ BC.concat ["You have been kicked: ", reason]
        Nothing     -> return $ do
          eitherMsg <- race (atomically $ readTChan lcChan) (atomically $ readTChan lcBrdChan)
          cont <- handleMsg srv clt (getAny eitherMsg)
          when cont serverTrd
    getAny (Left msg)  = msg
    getAny (Right msg) = msg
runClient _ _ = return ()

addClient ::  Server
           -> ClientName
           -> Handle
           -> IO (Maybe Client)
addClient srv@Server{..} name hdl = atomically $ do
  clientMap <- readTVar srvClients
  if Map.member name clientMap
    then return Nothing
    else do
      lc <- mkLocalClient name hdl srvChanBrd
      let client = LC lc
      writeTVar srvClients $ Map.insert name client clientMap
      broadcast srv $ conMsg $ BC.intercalate ", " (Map.keys clientMap)
      brdRemote srv $ MsgClientNew name srvPid
      return $ Just client
  where
    conMsg allNames = connectMsg [name, " has connected. Welcome by: (", allNames, ")"]

removeClient ::  Server
              -> ClientName
              -> IO ()
removeClient srv@Server{..} name = atomically $ do
  modifyTVar' srvClients $ Map.delete name
  broadcast srv $ clientDisconnect name
  brdRemote srv $ MsgClientDiscon name srvPid
  where clientDisconnect n  = connectMsg [n, " has disconnected"]

-- ---- Helpers ----

connectMsg :: [ByteString] -> Msg
connectMsg =  Notice . BC.concat
