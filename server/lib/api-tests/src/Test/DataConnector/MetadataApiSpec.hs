{-# LANGUAGE QuasiQuotes #-}
-- For runWithLocalTestEnvironmentSingleSetup
{-# OPTIONS_GHC -Wno-deprecations #-}

-- | Metadata API tests for Data Connector Backend
module Test.DataConnector.MetadataApiSpec (spec) where

--------------------------------------------------------------------------------

import Control.Lens qualified as Lens
import Data.Aeson qualified as J
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Lens
import Data.List.NonEmpty qualified as NE
import Data.Vector qualified as Vector
import Harness.Backend.DataConnector.Chinook qualified as Chinook
import Harness.Backend.DataConnector.Chinook.Reference qualified as Reference
import Harness.Backend.DataConnector.Chinook.Sqlite qualified as Sqlite
import Harness.GraphqlEngine qualified as GraphqlEngine
import Harness.Quoter.Yaml (yaml)
import Harness.Test.BackendType (BackendTypeConfig (..))
import Harness.Test.BackendType qualified as BackendType
import Harness.Test.Fixture qualified as Fixture
import Harness.TestEnvironment (GlobalTestEnvironment, TestEnvironment)
import Harness.TestEnvironment qualified as TestEnvironment
import Harness.Yaml (shouldReturnYaml, shouldReturnYamlF)
import Hasura.Prelude
import Test.Hspec (SpecWith, describe, it, pendingWith)

--------------------------------------------------------------------------------
-- DataConnector Agent Query Tests

spec :: SpecWith GlobalTestEnvironment
spec = do
  Fixture.runWithLocalTestEnvironmentSingleSetup
    ( NE.fromList
        [ (Fixture.fixture $ Fixture.Backend Reference.backendTypeMetadata)
            { Fixture.setupTeardown = \(testEnv, _) ->
                [emptySetupAction testEnv]
            },
          (Fixture.fixture $ Fixture.Backend Sqlite.backendTypeMetadata)
            { Fixture.setupTeardown = \(testEnv, _) ->
                [emptySetupAction testEnv]
            }
        ]
    )
    schemaCrudTests

  Fixture.runWithLocalTestEnvironmentSingleSetup
    ( NE.fromList
        [ (Fixture.fixture $ Fixture.Backend Reference.backendTypeMetadata)
            { Fixture.setupTeardown = \(testEnv, _) ->
                [Chinook.setupAction Chinook.referenceSourceConfig Reference.agentConfig testEnv]
            },
          (Fixture.fixture $ Fixture.Backend Sqlite.backendTypeMetadata)
            { Fixture.setupTeardown = \(testEnv, _) ->
                [Chinook.setupAction Chinook.sqliteSourceConfig Sqlite.agentConfig testEnv]
            }
        ]
    )
    schemaInspectionTests

--------------------------------------------------------------------------------

schemaInspectionTests :: Fixture.Options -> SpecWith (TestEnvironment, a)
schemaInspectionTests opts = describe "Schema and Source Inspection" $ do
  describe "get_source_tables" $ do
    it "success" $ \(testEnvironment, _) -> do
      let sortYamlArray :: J.Value -> IO J.Value
          sortYamlArray (J.Array a) = pure $ J.Array (Vector.fromList (sort (Vector.toList a)))
          sortYamlArray _ = fail "Should return Array"

      case BackendType.backendSourceName <$> TestEnvironment.backendTypeConfig testEnvironment of
        Nothing -> pendingWith "Backend not found for testEnvironment"
        Just sourceString -> do
          shouldReturnYamlF
            sortYamlArray
            opts
            ( GraphqlEngine.postMetadata
                testEnvironment
                [yaml|
                type: get_source_tables
                args:
                  source: *sourceString
              |]
            )
            [yaml|
              - - Album
              - - Artist
              - - Customer
              - - Employee
              - - Genre
              - - Invoice
              - - InvoiceLine
              - - MediaType
              - - Playlist
              - - PlaylistTrack
              - - Track
            |]

  describe "get_table_info" $ do
    it "success" $ \(testEnvironment, _) -> do
      let removeDescriptions (J.Object o) = J.Object (KM.delete "description" (removeDescriptions <$> o))
          removeDescriptions (J.Array a) = J.Array (removeDescriptions <$> a)
          removeDescriptions x = x

      case BackendType.backendSourceName <$> TestEnvironment.backendTypeConfig testEnvironment of
        Nothing -> pendingWith "Backend not found for testEnvironment"
        Just sourceString -> do
          shouldReturnYamlF
            (pure . removeDescriptions)
            opts
            ( GraphqlEngine.postMetadata
                testEnvironment
                [yaml|
                  type: get_table_info
                  args:
                    source: *sourceString
                    table:
                      - Genre
                |]
            )
            [yaml|
              columns:
              - name: GenreId
                nullable: false
                type: number
              - name: Name
                nullable: true
                type: string
              name:
              - Genre
              primary_key:
              - GenreId
            |]

  describe "get_source_kind_capabilities" $ do
    it "success" $ \(testEnvironment, _) -> do
      case ( BackendType.backendCapabilities =<< TestEnvironment.backendTypeConfig testEnvironment,
             BackendType.backendTypeString <$> TestEnvironment.backendTypeConfig testEnvironment
           ) of
        (Nothing, _) -> pendingWith "Capabilities not found in testEnvironment"
        (_, Nothing) -> pendingWith "Backend Type not found in testEnvironment"
        (Just backendCapabilities, Just backendString) -> do
          shouldReturnYaml
            opts
            ( ( GraphqlEngine.postMetadata
                  testEnvironment
                  [yaml|
                type: get_source_kind_capabilities
                args:
                  name: *backendString
              |]
              ) -- Note: These fields are backend specific so we ignore their values and just verify their shapes:
                <&> Lens.set (key "config_schema_response" . key "other_schemas") J.Null
                  . Lens.set (key "config_schema_response" . key "config_schema") J.Null
                  . Lens.set (key "options" . key "uri") J.Null
                  . Lens.set (_Object . Lens.at "display_name") (Just J.Null)
            )
            [yaml|
            capabilities: *backendCapabilities
            config_schema_response:
              config_schema: null
              other_schemas: null
            display_name: null
            options:
              uri: null
            |]

schemaCrudTests :: Fixture.Options -> SpecWith (TestEnvironment, a)
schemaCrudTests opts = describe "A series of actions to setup and teardown a source with tracked tables and relationships" $ do
  describe "dc_add_agent" $ do
    it "Success" $ \(testEnvironment, _) -> do
      case ( backendServerUrl =<< TestEnvironment.backendTypeConfig testEnvironment,
             backendTypeString <$> TestEnvironment.backendTypeConfig testEnvironment
           ) of
        (Nothing, _) -> pendingWith "Capabilities not found in testEnvironment"
        (_, Nothing) -> pendingWith "Backend Type not found in testEnvironment"
        (Just serverString, Just backendString) -> do
          shouldReturnYaml
            opts
            ( GraphqlEngine.postMetadata
                testEnvironment
                [yaml|
                type: dc_add_agent
                args:
                  name: *backendString
                  url: *serverString
              |]
            )
            [yaml|
              message: success
            |]

  describe "list_source_kinds" $ do
    it "success" $ \(testEnvironment, _) -> do
      case (backendTypeString &&& backendDisplayNameString) <$> TestEnvironment.backendTypeConfig testEnvironment of
        Nothing -> pendingWith "Backend Type not found in testEnvironment"
        Just (backendString, backendDisplayName) -> do
          shouldReturnYaml
            opts
            ( GraphqlEngine.postMetadata
                testEnvironment
                [yaml|
                type: list_source_kinds
                args: {}
              |]
            )
            [yaml|
              sources:
              - builtin: true
                kind: pg
                display_name: pg
              - builtin: true
                kind: citus
                display_name: citus
              - builtin: true
                kind: cockroach
                display_name: cockroach
              - builtin: true
                kind: mssql
                display_name: mssql
              - builtin: true
                kind: bigquery
                display_name: bigquery
              - builtin: true
                kind: mysql
                display_name: mysql
              - builtin: false
                kind: *backendString
                display_name: *backendDisplayName
              - builtin: false
                display_name: "FOOBARDB (foobar)"
                kind: foobar
            |]

  describe "<kind>_add_source" $ do
    it "success" $ \(testEnvironment@TestEnvironment.TestEnvironment {..}, _) -> do
      let actionType = foldMap BackendType.backendTypeString backendTypeConfig <> "_add_source"
      when (fmap backendType (TestEnvironment.backendTypeConfig testEnvironment) == Just Fixture.DataConnectorSqlite) (pendingWith "TODO: Test currently broken for SQLite DataConnector")
      shouldReturnYaml
        opts
        ( GraphqlEngine.postMetadata
            testEnvironment
            [yaml|
            type: *actionType
            args:
              name: chinook
              configuration:
                value: {}
          |]
        )
        [yaml|
          message: success
        |]

  describe "<kind>_track_table" $ do
    it "success" $ \(testEnvironment, _) -> do
      when (fmap backendType (TestEnvironment.backendTypeConfig testEnvironment) == Just Fixture.DataConnectorSqlite) (pendingWith "TODO: Test currently broken for SQLite DataConnector")
      shouldReturnYaml
        opts
        ( GraphqlEngine.postMetadata
            testEnvironment
            [yaml|
            type: reference_track_table
            args:
              source: chinook
              table: Album
          |]
        )
        [yaml|
          message: success
        |]

  describe "<kind>_create_object_relationship" $ do
    it "success" $ \(testEnvironment, _) -> do
      when (fmap backendType (TestEnvironment.backendTypeConfig testEnvironment) == Just Fixture.DataConnectorSqlite) (pendingWith "TODO: Test currently broken for SQLite DataConnector")
      GraphqlEngine.postMetadata_
        testEnvironment
        [yaml|
        type: reference_track_table
        args:
          source: chinook
          table: Artist
      |]

      shouldReturnYaml
        opts
        ( GraphqlEngine.postMetadata
            testEnvironment
            [yaml|
            type: reference_create_object_relationship
            args:
              source: chinook
              table: Album
              name: Artist
              using:
                foreign_key_constraint_on:
                  - ArtistId
          |]
        )
        [yaml|
          message: success
        |]

  describe "<kind>_create_array_relationship" $ do
    it "success" $ \(testEnvironment, _) -> do
      when (fmap backendType (TestEnvironment.backendTypeConfig testEnvironment) == Just Fixture.DataConnectorSqlite) (pendingWith "TODO: Test currently broken for SQLite DataConnector")
      shouldReturnYaml
        opts
        ( GraphqlEngine.postMetadata
            testEnvironment
            [yaml|
            type: reference_create_array_relationship
            args:
              source: chinook
              table: Artist
              name: Albums
              using:
                foreign_key_constraint_on:
                  table: Album
                  columns:
                    - ArtistId
          |]
        )
        [yaml|
          message: success
        |]

  describe "export_metadata" $ do
    it "produces the expected metadata structure" $ \(testEnvironment, _) -> do
      when (fmap backendType (TestEnvironment.backendTypeConfig testEnvironment) == Just Fixture.DataConnectorSqlite) (pendingWith "TODO: Test currently broken for SQLite DataConnector")
      shouldReturnYaml
        opts
        ( GraphqlEngine.postMetadata
            testEnvironment
            [yaml|
            type: export_metadata
            args: {}
          |]
        )
        [yaml|
          backend_configs:
            dataconnector:
              reference:
                uri: http://localhost:65005
          sources:
          - configuration:
              template: null
              timeout: null
              value: {}
            kind: reference
            name: chinook
            tables:
            - object_relationships:
              - name: Artist
                using:
                  foreign_key_constraint_on: ArtistId
              table:
              - Album
            - array_relationships:
              - name: Albums
                using:
                  foreign_key_constraint_on:
                    column: ArtistId
                    table:
                    - Album
              table:
              - Artist
          version: 3
        |]

  describe "<kind>_drop_relationship" $ do
    it "success" $ \(testEnvironment, _) -> do
      when (fmap backendType (TestEnvironment.backendTypeConfig testEnvironment) == Just Fixture.DataConnectorSqlite) (pendingWith "TODO: Test currently broken for SQLite DataConnector")
      shouldReturnYaml
        opts
        ( GraphqlEngine.postMetadata
            testEnvironment
            [yaml|
            type: reference_drop_relationship
            args:
              source: chinook
              table: Artist
              relationship: Albums
          |]
        )
        [yaml|
          message: success
        |]

  describe "<kind>_untrack_table" $ do
    it "success" $ \(testEnvironment, _) -> do
      when (fmap backendType (TestEnvironment.backendTypeConfig testEnvironment) == Just Fixture.DataConnectorSqlite) (pendingWith "TODO: Test currently broken for SQLite DataConnector")
      shouldReturnYaml
        opts
        ( GraphqlEngine.postMetadata
            testEnvironment
            [yaml|
            type: reference_untrack_table
            args:
              source: chinook
              table: Artist
              cascade: true
          |]
        )
        [yaml|
          message: success
        |]

  describe "<kind>_drop_source" $ do
    it "success" $ \(testEnvironment, _) -> do
      when (fmap backendType (TestEnvironment.backendTypeConfig testEnvironment) == Just Fixture.DataConnectorSqlite) (pendingWith "TODO: Test currently broken for SQLite DataConnector")
      shouldReturnYaml
        opts
        ( GraphqlEngine.postMetadata
            testEnvironment
            [yaml|
            type: reference_drop_source
            args:
              name: chinook
              cascade: true
          |]
        )
        [yaml|
          message: success
        |]

  describe "dc_delete_agent" $ do
    it "success" $ \(testEnvironment, _) -> do
      case BackendType.backendTypeString <$> TestEnvironment.backendTypeConfig testEnvironment of
        Nothing -> pendingWith "Backend Type not found in testEnvironment"
        Just backendString -> do
          shouldReturnYaml
            opts
            ( GraphqlEngine.postMetadata
                testEnvironment
                [yaml|
                type: dc_delete_agent
                args:
                  name: *backendString
              |]
            )
            [yaml|
              message: success
            |]

-- | Setup a test action without any initialization then reset the
-- metadata in the teardown. This is useful for running tests on the Metadata API.
emptySetupAction :: TestEnvironment -> Fixture.SetupAction
emptySetupAction testEnvironment =
  Fixture.SetupAction
    { setupAction = pure (),
      teardownAction = const $ GraphqlEngine.clearMetadata testEnvironment
    }