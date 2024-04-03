{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -Wno-partial-fields #-}

module Language.EO.Phi.Report.Data where

import Data.Aeson (FromJSON, ToJSON)
import GHC.Generics (Generic)
import Language.EO.Phi.Metrics.Data (BindingMetrics (..), Metrics (..), MetricsCount, ProgramMetrics)
import Language.EO.Phi.Metrics.Data qualified as Metrics
import Language.EO.Phi.TH (deriveJSON)
import Text.Printf (printf)
import Prelude hiding (div, id, span)

data ReportItem = ReportItem
  { phi :: FilePath
  , phiNormalized :: FilePath
  , bindingsPathPhi :: Maybe String
  , bindingsPathPhiNormalized :: Maybe String
  }
  deriving stock (Show, Generic)

$(deriveJSON ''ReportItem)

data MetricsChangeCategory a
  = MetricsChange'Good {change :: a}
  | MetricsChange'Bad {change :: a}
  | MetricsChange'NA
  deriving stock (Show, Generic, Eq)

$(deriveJSON ''MetricsChangeCategory)

type MetricsChange = Metrics Percent

newtype Percent = Percent {percent :: Double}
  deriving newtype
    (FromJSON, ToJSON, Num, Fractional, Floating, Eq, Ord, Real, RealFrac, RealFloat)

roundToStr :: Int -> Double -> String
roundToStr = printf "%0.*f%%"

instance Show Percent where
  show :: Percent -> String
  show Percent{..} = roundToStr 2 (percent * 100)

type MetricsChangeCategorized = Metrics (MetricsChangeCategory Percent)

data Report'InputConfig = Report'InputConfig
  { js :: Maybe FilePath
  , css :: Maybe FilePath
  }
  deriving stock (Show, Generic)

$(deriveJSON ''Report'InputConfig)

data Report'OutputConfig = Report'OutputConfig
  { html :: Maybe FilePath
  , json :: Maybe FilePath
  , markdown :: Maybe FilePath
  }
  deriving stock (Show, Generic)

$(deriveJSON ''Report'OutputConfig)

data ReportConfig = ReportConfig
  { input :: Maybe Report'InputConfig
  , output :: Report'OutputConfig
  , expectedMetricsChange :: MetricsChange
  , expectedImprovedProgramsPercentage :: Percent
  , items :: [ReportItem]
  }
  deriving stock (Show, Generic)

$(deriveJSON ''ReportConfig)

data ReportRow = ReportRow
  { fileInitial :: Maybe FilePath
  , fileNormalized :: Maybe FilePath
  , bindingsPathInitial :: Maybe Metrics.Path
  , bindingsPathNormalized :: Maybe Metrics.Path
  , attributeInitial :: Maybe String
  , attributeNormalized :: Maybe String
  , metricsChange :: MetricsChangeCategorized
  , metricsInitial :: Metrics Int
  , metricsNormalized :: Metrics Int
  }

$(deriveJSON ''ReportRow)

data ProgramReport = ProgramReport
  { programRow :: ReportRow
  , bindingsRows :: [ReportRow]
  }

$(deriveJSON ''ProgramReport)

data Report = Report
  { totalRow :: ReportRow
  , programReports :: [ProgramReport]
  }

$(deriveJSON ''Report)

-- >>> calculateMetricsChange Metrics { dataless = 0.1, applications = 0.2, formations = 0.2, dispatches = 0.2 } Metrics { dataless = 100, applications = 0, formations = 100, dispatches = 100 } Metrics { dataless = 90, applications = 0, formations = 93, dispatches = 60 }
-- Metrics {formations = MetricsChange'Bad {change = 7.00%}, dataless = MetricsChange'Good {change = 10.00%}, applications = MetricsChange'NA, dispatches = MetricsChange'Good {change = 40.00%}}
calculateMetricsChange :: MetricsChange -> MetricsCount -> MetricsCount -> MetricsChangeCategorized
calculateMetricsChange expectedMetricsChange countInitial countNormalized =
  getMetricsChangeClassified <$> expectedMetricsChange <*> actualMetricsChange
 where
  isFinite :: (RealFloat a) => a -> Bool
  isFinite x = not (isNaN x || isInfinite x)

  getMetricsChangeClassified :: Percent -> Percent -> MetricsChangeCategory Percent
  getMetricsChangeClassified expected actual
    | isFinite expected && isFinite actual =
        if actual >= expected
          then MetricsChange'Good actual
          else MetricsChange'Bad actual
    | otherwise = MetricsChange'NA

  actualMetricsChange :: MetricsChange
  actualMetricsChange = (initial - normalized) / initial
  initial = fromIntegral <$> countInitial
  normalized = fromIntegral <$> countNormalized

makeProgramReport :: ReportConfig -> ReportItem -> ProgramMetrics -> ProgramMetrics -> ProgramReport
makeProgramReport reportConfig reportItem metricsPhi metricsPhiNormalized =
  ProgramReport{..}
 where
  bindingsRows =
    case (metricsPhi.bindingsByPathMetrics, metricsPhiNormalized.bindingsByPathMetrics) of
      (Just bindingsMetricsNormalized, Just bindingsMetricsInitial) ->
        [ ReportRow
          { fileInitial = Just reportItem.phi
          , fileNormalized = Just reportItem.phiNormalized
          , bindingsPathInitial = Just bindingsMetricsNormalized.path
          , bindingsPathNormalized = Just bindingsMetricsNormalized.path
          , attributeInitial = Just attributeInitial
          , attributeNormalized = Just attributeNormalized
          , metricsChange = calculateMetricsChange reportConfig.expectedMetricsChange metricsInitial metricsNormalized
          , metricsInitial = metricsInitial
          , metricsNormalized = metricsNormalized
          }
        | BindingMetrics{name = attributeInitial, metrics = metricsInitial} <- bindingsMetricsInitial.bindingsMetrics
        | BindingMetrics{name = attributeNormalized, metrics = metricsNormalized} <- bindingsMetricsNormalized.bindingsMetrics
        ]
      _ -> []
  programRow =
    ReportRow
      { fileInitial = Just reportItem.phi
      , fileNormalized = Just reportItem.phiNormalized
      , bindingsPathInitial = Nothing
      , bindingsPathNormalized = Nothing
      , attributeInitial = Nothing
      , attributeNormalized = Nothing
      , metricsChange = calculateMetricsChange reportConfig.expectedMetricsChange metricsPhi.programMetrics metricsPhiNormalized.programMetrics
      , metricsInitial = metricsPhi.programMetrics
      , metricsNormalized = metricsPhiNormalized.programMetrics
      }

makeReport :: ReportConfig -> [ProgramReport] -> Report
makeReport reportConfig programReports =
  Report{..}
 where
  programRows = (.programRow) <$> programReports
  metricsInitial = foldMap (.metricsInitial) programRows
  metricsNormalized = foldMap (.metricsNormalized) programRows
  metricsChange = calculateMetricsChange reportConfig.expectedMetricsChange metricsInitial metricsNormalized
  totalRow =
    ReportRow
      { fileInitial = Nothing
      , fileNormalized = Nothing
      , bindingsPathInitial = Nothing
      , bindingsPathNormalized = Nothing
      , attributeInitial = Nothing
      , attributeNormalized = Nothing
      , ..
      }
