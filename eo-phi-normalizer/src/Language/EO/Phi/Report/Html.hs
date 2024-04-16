{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -Wno-orphans #-}
{-# OPTIONS_GHC -Wno-partial-fields #-}

module Language.EO.Phi.Report.Html where

import Data.FileEmbed (embedFileRelative)
import Data.List (intercalate)
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Language.EO.Phi.Metrics.Data (Metrics (..), MetricsCount, toListMetrics)
import Language.EO.Phi.Report.Data (MetricsChange, MetricsChangeCategorized, MetricsChangeCategory (..), Percent (..), ProgramReport (..), Report (..), ReportRow (..))
import PyF (fmt)
import Text.Blaze.Html.Renderer.String (renderHtml)
import Text.Blaze.Html5 hiding (i)
import Text.Blaze.Html5.Attributes (class_, colspan, id, onclick, type_, value)
import Prelude hiding (div, id, span)

-- $setup
-- >>> import Text.Blaze.Html.Renderer.String (renderHtml)

-- | JavaScript file to embed into HTML reports
reportJS :: String
reportJS = T.unpack $ T.decodeUtf8 $(embedFileRelative "report/main.js")

-- | CSS file to embed into HTML reports
reportCSS :: String
reportCSS = T.unpack $ T.decodeUtf8 $(embedFileRelative "report/styles.css")

metricsNames :: Metrics String
metricsNames =
  Metrics
    { dataless = "Dataless formations"
    , applications = "Applications"
    , formations = "Formations"
    , dispatches = "Dispatches"
    }

toHtmlReportHeader :: Html
toHtmlReportHeader =
  thead $
    toHtml
      [ tr $
          toHtml
            [ th ! colspan "2" ! class_ "no-sort" $ "Attribute"
            , th ! colspan "4" ! class_ "no-sort" $ "Change"
            , th ! colspan "4" ! class_ "no-sort" $ "Initial"
            , th ! colspan "4" ! class_ "no-sort" $ "Normalized"
            , th ! colspan "4" ! class_ "no-sort" $ "Location"
            ]
      , tr . toHtml $
          th
            <$> [ "Attribute Initial"
                , "Attribute Normalized"
                ]
              <> ( concat
                    . replicate 3
                    . (toHtml <$>)
                    $ toListMetrics metricsNames
                 )
              <> [ "File Initial"
                 , "Bindings Path Initial"
                 , "File Normalized"
                 , "Bindings Path Normalized"
                 ]
      ]

data ReportFormat
  = ReportFormat'Html
      { css :: String
      , js :: String
      }
  | -- | GitHub Flavored Markdown
    ReportFormat'Markdown
  deriving stock (Eq)

data ReportConfig = ReportConfig
  { expectedMetricsChange :: MetricsChange
  , expectedImprovedProgramsPercentage :: Percent
  , format :: ReportFormat
  }

instance ToMarkup Percent where
  toMarkup :: Percent -> Markup
  toMarkup = toMarkup . show

-- >>> reportConfig = ReportConfig { expectedMetricsChange = 0, format = ReportFormat'Markdown }
--
-- >>> renderHtml $ toHtmlChange reportConfig (MetricsChange'Bad 0.2)
-- "<td class=\"number bad\">0.2\128308</td>"
--
-- >>> renderHtml $ toHtmlChange reportConfig (MetricsChange'Good 0.5)
-- "<td class=\"number good\">0.5\128994</td>"
-- >>> renderHtml $ toHtmlChange reportConfig (MetricsChange'NA :: MetricsChangeCategory Double)
-- "<td class=\"number not-applicable\">N/A\128995</td>"
toHtmlChange :: (ToMarkup a) => ReportConfig -> MetricsChangeCategory a -> Html
toHtmlChange reportConfig = \case
  MetricsChange'NA -> td ! class_ "number not-applicable" $ toHtml ("N/A" :: String) <> toHtml ['🟣' | isMarkdown]
  MetricsChange'Bad{..} -> td ! class_ "number bad" $ toHtml change <> toHtml ['🔴' | isMarkdown]
  MetricsChange'Good{..} -> td ! class_ "number good" $ toHtml change <> toHtml ['🟢' | isMarkdown]
 where
  isMarkdown = reportConfig.format == ReportFormat'Markdown

toHtmlMetricsChange :: ReportConfig -> MetricsChangeCategorized -> [Html]
toHtmlMetricsChange reportConfig change = toHtmlChange reportConfig <$> toListMetrics change

toHtmlMetrics :: MetricsCount -> [Html]
toHtmlMetrics metrics =
  (td ! class_ "number")
    . toHtml
    <$> toListMetrics metrics

toHtmlReportRow :: ReportConfig -> ReportRow -> Html
toHtmlReportRow reportConfig reportRow =
  tr . toHtml $
    ( td
        . toHtml
        <$> [ fromMaybe "[N/A]" reportRow.attributeInitial
            , fromMaybe "[N/A]" reportRow.attributeNormalized
            ]
    )
      <> toHtmlMetricsChange reportConfig reportRow.metricsChange
      <> toHtmlMetrics reportRow.metricsInitial
      <> toHtmlMetrics reportRow.metricsNormalized
      <> ( td
            . toHtml
            <$> [ fromMaybe "[all programs]" reportRow.fileInitial
                , intercalate "." $ fromMaybe ["[whole program]"] reportRow.bindingsPathInitial
                , fromMaybe "[all programs]" reportRow.fileNormalized
                , intercalate "." $ fromMaybe ["[whole program]"] reportRow.bindingsPathNormalized
                ]
         )

toHtmlReport :: ReportConfig -> Report -> Html
toHtmlReport reportConfig report =
  toHtml $
    [ h2 "Overview"
        <> p
          [fmt|
            We translate EO files into initial PHI programs.
            Next, we normalize these programs and get normalized PHI programs.
            Then, we collect metrics for initial and normalized PHI programs.
          |]
        <> h2 "Metrics"
        <> p
          [fmt|
            An EO file contains multiple test objects.
            After translation, these test objects become attributes in PHI programs.
            We call these attributes "tests".
          |]
        <> p
          [fmt|
            We collect metrics on the number of {intercalate ", " (toListMetrics metricsNames)} in tests.
            We want normalized tests to have less such elements than initial tests do.
          |]
        <> p "A metric change for a test is calculated by the formula"
        <> p (code "(metric_initial - metric_normalized) / metric_initial")
        <> p "where:"
        <> ul
          ( toHtml
              [ li $ code "metric_initial" <> " is the metric for the initial test"
              , li $ code "metric_normalized" <> " is the metric for the normalized test"
              ]
          )
        <> h3 "Expected"
        <> p
          [fmt|
            Metric changes are expected to be as follows or greater:
          |]
        <> ul
          ( toHtml . toListMetrics $
              mkPercentItem
                <$> metricsNames
                <*> reportConfig.expectedMetricsChange
          )
        <> p
          ( let expectedImprovedProgramsPercentage = reportConfig.expectedImprovedProgramsPercentage
             in [fmt|We expect such changes for at least {expectedImprovedProgramsPercentage:s} of tests.|]
          )
        <> h3 "Actual"
        <> p [fmt|We normalized {testsCount} tests.|]
        <> p [fmt|All metrics were improved for {mkNumber allGoodMetricsCount testsCount} tests.|]
        <> p [fmt|Tests where a particular metric was improved:|]
        <> ul
          ( toHtml . toListMetrics $
              mkItem'
                <$> metricsNames
                <*> particularMetricsChangeGoodCount
          )
        <> h2 "Table"
        <> p [fmt|The table below provides detailed information about tests.|]
    ]
      <> [
         -- https://stackoverflow.com/a/55743302
         -- https://stackoverflow.com/a/3169849
         ( script ! type_ "text/javascript" $
            [fmt|
                function copytable(el) {{
                  var urlField = document.getElementById(el)
                  var range = document.createRange()
                  range.selectNode(urlField)
                  window.getSelection().addRange(range)
                  document.execCommand('copy')

                  if (window.getSelection().empty) {{  // Chrome
                    window.getSelection().empty();
                  }} else if (window.getSelection().removeAllRanges) {{  // Firefox
                    window.getSelection().removeAllRanges();
                  }}
                }}
              |]
         )
          <> (input ! type_ "button" ! value "Copy to Clipboard" ! onclick "copytable('table')")
          <> h3 "Columns"
          <> p "Columns in this table are sortable."
          <> p "Hover over a header cell from the second row of header cells (Attribute Initial, etc.) to see a triangle demonstrating the sorting order."
          <> ul
            ( toHtml
                [ li "▾: descending"
                , li "▴: ascending"
                , li "▸: unordered"
                ]
            )
          <> p "Click on the triangle to change the sorting order in the corresponding column."
         | not isMarkdown
         ]
      <> [ table ! class_ "sortable" ! id "table" $
            toHtml
              [ toHtmlReportHeader
              , tbody . toHtml $
                  toHtmlReportRow reportConfig
                    <$> concat [programReport.bindingsRows | programReport <- report.programReports]
              ]
         ]
      <> ( case reportConfig.format of
            ReportFormat'Html{..} ->
              [ style ! type_ "text/css" $ toHtml css
              , script $ toHtml js
              ]
            ReportFormat'Markdown -> []
         )
 where
  isMarkdown = reportConfig.format == ReportFormat'Markdown

  tests = concatMap (.bindingsRows) report.programReports

  testsCount = length tests

  metricsChanges = (.metricsChange) <$> concatMap (.bindingsRows) report.programReports

  isGood = \case
    MetricsChange'Good _ -> True
    _ -> False

  countAllMetricsSatisfyingCondition cond = length $ filter (all cond) metricsChanges
  allGoodMetricsCount = countAllMetricsSatisfyingCondition isGood

  particularMetricsChangeGoodCount :: Metrics Int
  particularMetricsChangeGoodCount = sum $ ((\x -> if x then 1 else 0) . isGood <$>) <$> metricsChanges

  mkItem' = mkItem testsCount

-- |
-- >>> renderHtml (mkItem 10 "foo" 4)
-- "<li><b>foo: </b>4 (40.00%)</li>"
mkItem :: Int -> String -> Int -> Html
mkItem total name part = li $ b [fmt|{name}: |] <> toHtml (mkNumber part total)

mkPercentItem :: String -> Percent -> Html
mkPercentItem name percent = li $ b [fmt|{name}: |] <> toHtml percent

mkPercentage :: Int -> Int -> Percent
mkPercentage part total = Percent $ fromIntegral part / fromIntegral total

-- |
-- >>> mkNumber 3 5
-- "3 (60.00%)"
mkNumber :: Int -> Int -> String
mkNumber part total = [fmt|{part} ({mkPercentage part total:s})|]

toStringReport :: ReportConfig -> Report -> String
toStringReport reportConfig report = renderHtml $ toHtmlReport reportConfig report
