-- |
-- Description : High-level environment variables management functions
-- Copyright   : (c) 2015 Egor Tensin <Egor.Tensin@gmail.com>
-- License     : MIT
-- Maintainer  : Egor.Tensin@gmail.com
-- Stability   : experimental
-- Portability : Windows-only
--
-- High-level functions for reading and writing Windows environment variables.

{-# LANGUAGE CPP #-}

module WindowsEnv.Environment
    ( Profile(..)
    , profileKeyPath

    , VarName
    , VarValue(..)

    , query
    , engrave
    , wipe

    , pathJoin
    , pathSplit

    , expand
    , ExpandedPath(..)
    , pathSplitAndExpand
    ) where

import           Control.Monad.Trans.Class  (lift)
import           Control.Monad.Trans.Except (ExceptT(..))
import           Data.List             (intercalate)
import           Data.List.Split       (splitOn)
import           Foreign.Marshal.Alloc (allocaBytes)
import           Foreign.Storable      (sizeOf)
import           System.IO.Error       (catchIOError)
import qualified System.Win32.Types    as WinAPI

import qualified WindowsEnv.Registry as Registry
import           WindowsEnv.Utils    (notifyEnvironmentUpdate)

data Profile = CurrentUser
             | AllUsers
             deriving (Eq, Show)

profileKeyPath :: Profile -> Registry.KeyPath
profileKeyPath CurrentUser = Registry.KeyPath Registry.CurrentUser ["Environment"]
profileKeyPath AllUsers    = Registry.KeyPath Registry.LocalMachine
    [ "SYSTEM"
    , "CurrentControlSet"
    , "Control"
    , "Session Manager"
    , "Environment"
    ]

type VarName = String

data VarValue = VarValue
    { varValueExpandable :: Bool
    , varValueString :: String
    } deriving (Eq)

instance Show VarValue where
    show = varValueString

valueFromRegistry :: Registry.StringValue -> VarValue
valueFromRegistry (valueType, valueData)
    | valueType == Registry.TypeString = VarValue False valueData
    | valueType == Registry.TypeExpandableString = VarValue True valueData
    | otherwise = error "WindowsEnv.Environment: unexpected"

valueToRegistry :: VarValue -> Registry.StringValue
valueToRegistry value
    | varValueExpandable value = (Registry.TypeExpandableString, varValueString value)
    | otherwise = (Registry.TypeString, varValueString value)

query :: Profile -> VarName -> ExceptT IOError IO VarValue
query profile name = valueFromRegistry <$> Registry.getStringValue (profileKeyPath profile) name

engrave :: Profile -> VarName -> VarValue -> ExceptT IOError IO ()
engrave profile name value = do
    ret <- Registry.setStringValue (profileKeyPath profile) name $ valueToRegistry value
    lift notifyEnvironmentUpdate
    return ret

wipe :: Profile -> VarName -> ExceptT IOError IO ()
wipe profile name = do
    ret <- Registry.deleteValue (profileKeyPath profile) name
    lift notifyEnvironmentUpdate
    return ret

pathSep :: String
pathSep = ";"

pathSplit :: String -> [String]
pathSplit = filter (not . null) . splitOn pathSep

pathJoin :: [String] -> String
pathJoin = intercalate pathSep . filter (not . null)

#include "ccall.h"

-- ExpandEnvironmentStrings isn't provided by Win32 (as of version 2.4.0.0).

foreign import WINDOWS_ENV_CCALL unsafe "Windows.h ExpandEnvironmentStringsW"
    c_ExpandEnvironmentStrings :: WinAPI.LPCTSTR -> WinAPI.LPTSTR -> WinAPI.DWORD -> IO WinAPI.ErrCode

expand :: String -> ExceptT IOError IO String
expand value = ExceptT $ catchIOError (Right <$> doExpand) (return . Left)
  where
    doExpandIn valuePtr bufferPtr bufferLength = do
        newBufferLength <- WinAPI.failIfZero "ExpandEnvironmentStringsW" $
            c_ExpandEnvironmentStrings valuePtr bufferPtr bufferLength
        let newBufferSize = (fromIntegral newBufferLength) * sizeOf (undefined :: WinAPI.TCHAR)
        if newBufferLength > bufferLength
            then allocaBytes newBufferSize $ \newBufferPtr -> doExpandIn valuePtr newBufferPtr newBufferLength
            else WinAPI.peekTString bufferPtr
    doExpand = WinAPI.withTString value $ \valuePtr -> doExpandIn valuePtr WinAPI.nullPtr 0

data ExpandedPath = ExpandedPath
    { pathOriginal :: String
    , pathExpanded :: String
    } deriving (Eq, Show)

pathSplitAndExpand :: String -> ExceptT IOError IO [ExpandedPath]
pathSplitAndExpand value = do
    expandedOnce <- expandOnce
    zipWith ExpandedPath originalPaths <$>
        if length expandedOnce == length originalPaths
            then return expandedOnce
            else expandEach
  where
    originalPaths = pathSplit value
    expandOnce = pathSplit <$> expand value
    expandEach = mapM expand originalPaths
