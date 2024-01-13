{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Test.EO.Phi where

import Control.Monad (forM)
import Data.Aeson (FromJSON (..))
import qualified Data.Yaml as Yaml
import GHC.Generics (Generic)
import System.Directory (listDirectory)
import System.FilePath ((</>))

import Data.List (sort)
import Language.EO.Phi (unsafeParseProgram)
import qualified Language.EO.Phi as Phi

data PhiTestGroup = PhiTestGroup
  { title :: String
  , tests :: [PhiTest]
  }
  deriving (Generic, FromJSON)

data PhiTest = PhiTest
  { name :: String
  , input :: Phi.Program
  , normalized :: Phi.Program
  , prettified :: String
  }
  deriving (Generic, FromJSON)

filePhiTests :: FilePath -> IO PhiTestGroup
filePhiTests = Yaml.decodeFileThrow

allPhiTests :: FilePath -> IO [PhiTestGroup]
allPhiTests dir = do
  paths <- listDirectory dir
  forM (sort paths) $ \path ->
    filePhiTests (dir </> path)

-- * Orphan instances

-- | Parsing a $\varphi$-program from a JSON string.
instance FromJSON Phi.Program where
  parseJSON = fmap unsafeParseProgram . parseJSON
