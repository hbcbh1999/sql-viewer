{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
module QueryParserView where

import Control.Monad (void, when)
import Control.Monad.Writer (runWriter)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Data
import Data.Foldable (forM_)
import Data.Functor.Identity (Identity(..))
import Data.JSString as JS (pack)
import Data.List (intersperse)
import qualified Data.Map as M
import Data.Text as T (Text, unpack)
import qualified Data.Text.Lazy as TL (Text, unpack)
import Data.Text.Lazy as TL (fromStrict, intercalate, toStrict)
import React.Flux
import React.Flux.DOM

import Catalog
import Dialects
import InputsStore
import ResolvedStore
import Tabs

import Database.Sql.Position (Range)
import Database.Sql.Type
import Database.Sql.Util.Columns
import Database.Sql.Util.Eval (RecordSet(..))
import Database.Sql.Util.Lineage.ColumnPlus
import Database.Sql.Util.Lineage.Table

queryView :: ReactView ()
queryView = defineControllerView "query" inputsStore $ \ Inputs{query} () -> do
  textarea_
    [ "value" &= query
    , onChange $ \ evt ->
        [SomeStoreAction inputsStore $ SetQuery $ target evt "value"]
    ] mempty

schemaView :: ReactView ()
schemaView = defineControllerView "schema" inputsStore $ \ Inputs{schema, path} () -> do
  textarea_
    [ "value" &= schema
    , onChange $ \ evt ->
        [SomeStoreAction inputsStore $ SetSchema $ target evt "value"]
    ] mempty
  br_ []
  input_
    [ "value" &= path
    , onChange $ \ evt ->
        [SomeStoreAction inputsStore $ SetPath $ target evt "value"]
    ]

data Example = Example
  { name :: !Text
  , dialect :: !SomeDialect
  , query :: !Text
  , schema :: !Text
  , path :: !Text
  }

renderExample :: Int -> Example -> ReactElementM handler ()
renderExample idx Example{..} = option_ [ "value" &= show idx ] $ elemText name

examplesView :: ReactView ()
examplesView = defineStatefulView "examples" 0 $ \ idx () -> do
  select_
    [ onChange $ \ evt _ ->
        case read $ T.unpack $ target evt "value" of
          new | new == idx -> ([], Nothing)
              | Just Example{..} <- lookup new examples
              -> ( map (SomeStoreAction inputsStore)
                    [ SetDialect dialect
                    , SetQuery query
                    , SetSchema schema
                    , SetPath path
                    ]
                 , Just new
                 )
              | otherwise -> ([], Just new)
    ] $ do
      option_ "examples"
      mapM_ (uncurry renderExample) examples
  where
    examples = zip [1..]
      [ Example
          { name = "CTAS"
          , dialect = SomeDialect (Proxy @Hive)
          , query = "CREATE TABLE bar AS SELECT * FROM foo WHERE a = 7;"
          , schema = defaultCatalog
          , path = "[\"public\"]"
          }
      ]

rawView :: ReactView ()
rawView = defineControllerView "raw" inputsStore $ \ Inputs{dialect = SomeDialect (_ :: Proxy dialect), query} () ->
  either elemShow renderAST $ parse @dialect $ fromStrict query

resolvedView :: ReactView ()
resolvedView = defineControllerView "resolved" resolvedStore $ \ (Resolved stmt) () -> either elemString renderAST stmt

columnsView :: ReactView ()
columnsView = defineControllerView "columns" resolvedStore $ \ (Resolved stmt) () ->
  case stmt of
    Left err -> elemString err
    Right stmt ->
      case getColumns stmt of
        columns
          | null columns -> "no column usage to report"
          | otherwise ->
              table_ $ do
                tr_ $ do
                  th_ "Column"
                  th_ "Clauses"
                forM_ columns $ \ (fqcn, clause) ->
                  tr_ $ do
                    td_ $ renderFQCN fqcn
                    td_ $ elemText $ toStrict clause

renderFQCN :: FQCN -> ReactElementM handler ()
renderFQCN FullyQualifiedColumnName{..} = elemText $ toStrict $ intercalate "." [fqcnSchemaName, fqcnTableName, fqcnColumnName]

renderFQTN :: FQTN -> ReactElementM handler ()
renderFQTN FullyQualifiedTableName{..} = elemText $ toStrict $ intercalate "." [fqtnSchemaName, fqtnTableName]

renderFQTNRowCount :: FQTN -> ReactElementM handler ()
renderFQTNRowCount fqtn = renderFQTN fqtn >> " row count"

renderColumnPlusSet :: ColumnPlusSet -> ReactElementM handler ()
renderColumnPlusSet ColumnPlusSet{..} =
  sequence_ $ intersperse (elemText ",\n") $
       map renderFQTNRowCount (M.keys columnPlusTables)
    ++ map renderFQCN (M.keys columnPlusColumns)

columnLineageView :: ReactView ()
columnLineageView = defineControllerView "column-lineage" resolvedStore $ \ (Resolved resolved) () ->
  case resolved of
    Left err -> elemString err
    Right stmt -> table_ $ do
      tr_ $ do
        th_ "Targets"
        th_ "Sources"
      case getColumnLineage stmt of
        (RecordSet{..}, effects) -> do
          let (columnSources, countSources) = runWriter recordSetItems
          when (mempty /= countSources) $ do
            tr_ $ do
              td_ "result row count"
              td_ $ renderColumnPlusSet countSources
          forM_ (zip recordSetLabels columnSources) $ \ (column, sources) -> do
            tr_ $ do
              td_ $
                let name =
                      case column of
                        RColumnRef (QColumnName _ _ name) -> name
                        RColumnAlias (ColumnAlias _ name _) -> name
                 in elemString ("result column " ++ TL.unpack name)
              td_ $ renderColumnPlusSet sources

          forM_ (M.toList effects) $ \ (target, sources) -> do
            tr_ $ do
              td_ $ either renderFQTNRowCount renderFQCN target
              td_ $ renderColumnPlusSet sources

tableLineageView :: ReactView ()
tableLineageView = defineControllerView "table-lineage" resolvedStore $ \ (Resolved resolved) () ->
  case resolved of
    Left err -> elemString err
    Right stmt ->
      case M.toList $ getTableLineage stmt of
        [] -> elemText "no table-level lineage to report"
        lineage -> do
          table_ $ do
            tr_ $ do
              th_ "Targets"
              th_ "Sources"
            forM_ lineage $ \ (target, sources) -> do
              td_ $ renderFQTN target
              td_ $ mapM_ renderFQTN sources

renderAST :: forall d handler. Data d => d -> ReactElementM handler ()
renderAST x
  | Just Refl <- eqT @d @T.Text
  = elemShow x
  | Just Refl <- eqT @d @TL.Text
  = elemShow x
  | Just Refl <- eqT @d @BS.ByteString
  = elemShow x
  | Just Refl <- eqT @d @BL.ByteString
  = elemShow x
  | Just Refl <- eqT @d @String
  = elemShow x
  | Just Refl <- eqT @d @(UQColumnName ())
  , QColumnName _ None columnName <- x
  = elemText $ toStrict columnName
  | Just Refl <- eqT @d @(UQColumnName Range)
  , QColumnName _ None columnName <- x
  = elemText $ toStrict columnName
  | Just Refl <- eqT @d @(FQColumnName Range)
  , QColumnName _ (Identity (QTableName _ (Identity (QSchemaName _ _ schemaName _)) tableName)) columnName <- x
  = elemText $ toStrict $ intercalate "." [schemaName, tableName, columnName]
  | Just Refl <- eqT @d @(FQTableName Range)
  , QTableName _ (Identity (QSchemaName _ _ schemaName _)) tableName <- x
  = elemText $ toStrict $ intercalate "." [schemaName, tableName]
  | Just Refl <- eqT @d @(ColumnAlias Range)
  , ColumnAlias _ name (ColumnAliasId aliasId) <- x
  = "ColumnAlias " >> elemString (show name) >> " (" >> elemString (show aliasId) >> ")"
  | Just Refl <- eqT @d @(TableAlias Range)
  , TableAlias _ name (TableAliasId aliasId) <- x
  = "TableAlias " >> elemString (show name) >> " (" >> elemString (show aliasId) >> ")"
  | dataIsList x
  = renderList x
  | otherwise
  = dl_ $ do
      dt_ $ elemShow (toConstr x)
      void $ gmapM (\ y -> skip (dd_ . renderAST) y >> pure y) x

dataIsNothing :: forall d. Data d => d -> Bool
dataIsNothing x =
  typeRepTyCon (typeRep (Proxy @d)) == typeRepTyCon (typeRep (Proxy @(Maybe ())))
    && toConstr x == toConstr (Nothing :: Maybe ())

dataIsList :: forall d. Data d => d -> Bool
dataIsList x = typeRepTyCon (typeRep (Proxy @d)) == typeRepTyCon (typeRep (Proxy @([()])))

renderList :: forall d handler. Data d => d -> ReactElementM handler ()
renderList x
  | toConstr x == toConstr ([] :: [()])
  = elemText "[]"
  | otherwise
  = ol_ $ renderListItems x

data SomeData = forall d. Data d => SomeData d

renderListItems :: forall d handler. Data d => d -> ReactElementM handler ()
renderListItems x
  | toConstr x == toConstr ([] :: [()])
  = pure ()
  | [SomeData h, SomeData t] <- gmapQ SomeData x
  = do
    li_ $ renderAST h
    renderListItems t

skip :: forall a m. (Monad m, Data a) => (forall d. Data d => d -> m ()) -> a -> m ()
skip f x
  | Just Refl <- eqT @a @Range
  = pure ()
  | dataIsNothing x
  = pure ()
  | otherwise
  = f x

dialect_ :: forall d. (KnownDialect d, Typeable d) => ReactElementM ViewEventHandler ()
dialect_ = viewWithSKey dialectView dialectName () mempty
  where
    dialectName = JS.pack $ show $ typeRep (Proxy @d)
    dialectView = defineControllerView dialectName inputsStore $ \ Inputs{dialect} () -> do
      div_ [ classNames [("control", True)] ] $ do
        input_
          [ "name" $= "dialect"
          , "checked" &= (dialect == SomeDialect (Proxy @d))
          , "value" &= dialectName
          , "id" &= dialectName
          , "type" $= "radio"
          , onChange $ \ _ -> [SomeStoreAction inputsStore $ SetDialect $ SomeDialect (Proxy @d)]
          ]
        label_ [ "for" &= dialectName ] $ elemJSString dialectName

queryParserView :: ReactView ()
queryParserView = defineView "query parser" $ \ () -> do
  div_ [classNames [("frame", True)]] $ do
    div_ [classNames [("controls", True)]] $ do
      dialect_ @Hive
      dialect_ @Presto
      dialect_ @Vertica
      div_ [ classNames [("control", True)] ]  $ viewWithSKey examplesView "examples" () mempty

    tabs_
      [ ( "Query"
        , viewWithSKey queryView "query" () mempty
        )
      , ( "Schema"
        , viewWithSKey schemaView "schema" () mempty
        )
      ]
  div_ [classNames [("frame", True)]] $ tabs_
    [ ( "AST"
      , tabs_
          [ ( "Raw"
            , viewWithSKey rawView "raw-query" () mempty
            )
          , ( "Resolved"
            , viewWithSKey resolvedView "resolved-query" () mempty
            )
          ]
      )
    , ( "Columns"
      , viewWithSKey columnsView "columns" () mempty
      )
    , ( "Lineage"
      , tabs_
        [ ( "Table"
          , viewWithSKey tableLineageView "table-lineage" () mempty
          )
        , ( "Column (Plus Fields and Row Count)"
          , viewWithSKey columnLineageView "column-lineage" () mempty
          )
        ]
      )
    , ( "Evaluation"
      , elemText "stub"
      )
    ] 
