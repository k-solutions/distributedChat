{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections   #-}

module Main where

import           Control.Distributed.Process
import qualified Control.Distributed.Process.Backend.SimpleLocalnet as DL
import           Control.Distributed.Process.Closure
import qualified Control.Distributed.Process.Node                   as DN
import           System.Environment                                 (getArgs)

import           ChatProcess

remotable ['chatServer]

myRemoteTable :: RemoteTable
myRemoteTable = Main.__remoteTable DN.initRemoteTable

localMaster :: [NodeId] -> Process ()
localMaster = singleMaster serverPort defClosure

defClosure = $(mkClosure 'chatServer)
serverPort = 8000

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["master"]            -> doMaster defHost defPort
    ["master", host]      -> doMaster host defPort
    ["slave", port]       -> doSlave defHost port
    ["slave", host, port] -> doSlave host port
    [port, chatPort]      -> defaultNode port chatPort
    _                     -> error "Bad parameters passed: Either [master] or [slave, port]!"
  where
    (defHost, defPort) = ("127.0.0.1", "8100")

    doSlave host port = do
      backend <-  DL.initializeBackend host port myRemoteTable
      DL.startSlave backend

    doMaster host port = do
      backend <- DL.initializeBackend host port myRemoteTable
      DL.startMaster backend localMaster -- defaultClosure

    defaultNode port chatPort = do
      backend <- DL.initializeBackend defHost port myRemoteTable
      node    <- DL.newLocalNode backend
      DN.runProcess node $ nodeMaster backend chatPort
