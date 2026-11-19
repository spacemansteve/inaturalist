# frozen_string_literal: true

class CreateSurveyProtocols < ActiveRecord::Migration[6.1]
  def up
    create_table :survey_protocols do | t |
      t.uuid :uuid, null: false, default: -> { "uuid_generate_v4()" }
      t.integer :user_id, null: false
      t.text :title, null: false
      t.text :description
      t.string :status, null: false, default: "draft"
      t.string :license
      t.text :source_url
      t.timestamps
    end
    add_index :survey_protocols, :uuid, unique: true
    add_index :survey_protocols, :user_id
    add_foreign_key :survey_protocols, :users
    add_check_constraint :survey_protocols, "btrim(title) <> ''", name: "survey_protocol_title"
    add_check_constraint :survey_protocols, "status IN ('draft','active','archived')", name: "survey_protocol_status"

    create_table :survey_protocol_versions do | t |
      t.references :survey_protocol, null: false, foreign_key: true, index: false
      t.integer :version_number, null: false
      t.text :instructions
      t.jsonb :definition, null: false, default: {}
      t.string :status, null: false, default: "draft"
      t.datetime :published_at
      t.timestamps
    end
    add_index :survey_protocol_versions, [:survey_protocol_id, :version_number], unique: true,
      name: "survey_version_number_unique"
    add_check_constraint :survey_protocol_versions, "version_number > 0", name: "survey_version_positive"
    add_check_constraint :survey_protocol_versions,
      "(status = 'draft' AND published_at IS NULL) OR (status IN ('published','retired') AND published_at IS NOT NULL)",
      name: "survey_version_lifecycle"

    create_table :survey_targets do | t |
      t.references :survey_protocol_version, null: false, foreign_key: true, index: false
      t.integer :taxon_id
      t.text :label, null: false
      t.string :scope_type, null: false
      t.jsonb :scope_definition, null: false, default: {}
      t.text :taxon_name_snapshot
      t.text :external_taxon_uri
      t.boolean :required, null: false, default: false
      t.integer :position
      t.timestamps
    end
    add_index :survey_targets, [:survey_protocol_version_id, :position], unique: true,
      name: "survey_target_position_unique"
    add_index :survey_targets, :taxon_id
    add_foreign_key :survey_targets, :taxa
    add_check_constraint :survey_targets, "btrim(label) <> ''", name: "survey_target_label"
    add_check_constraint :survey_targets, "position IS NULL OR position >= 0", name: "survey_target_position"
    add_check_constraint :survey_targets, <<~SQL.squish, name: "survey_target_scope"
      jsonb_typeof(scope_definition) = 'object' AND (
        (scope_type = 'taxon' AND taxon_id IS NOT NULL AND NULLIF(btrim(taxon_name_snapshot), '') IS NOT NULL
          AND scope_definition = '{}'::jsonb) OR
        (scope_type IN ('taxon_group','verbatim')
          AND jsonb_typeof(scope_definition->'description') = 'string'
          AND NULLIF(btrim(scope_definition->>'description'), '') IS NOT NULL
          AND scope_definition - 'description' = '{}'::jsonb
          AND (scope_type <> 'verbatim' OR taxon_id IS NULL)))
    SQL

    create_table :survey_measurement_definitions do | t |
      t.references :survey_protocol_version, null: false, foreign_key: true, index: false
      t.string :field_key, null: false
      t.text :label, null: false
      t.text :description
      t.string :data_type, null: false
      t.string :unit
      t.text :unit_uri
      t.text :vocabulary_uri
      t.jsonb :allowed_values, null: false, default: []
      t.jsonb :validation_rules, null: false, default: {}
      t.string :applies_to, null: false, default: "event"
      t.boolean :required, null: false, default: false
      t.timestamps
    end
    add_index :survey_measurement_definitions, [:survey_protocol_version_id, :field_key], unique: true,
      name: "survey_measurement_field_unique"
    add_check_constraint :survey_measurement_definitions,
      "field_key ~ '^[a-z][a-z0-9_]*$' AND btrim(label) <> ''", name: "survey_measurement_definition_label"
    add_check_constraint :survey_measurement_definitions,
      "data_type IN ('numeric','text','boolean','categorical') AND applies_to IN ('event','detection')",
      name: "survey_measurement_definition_type"
    execute File.read( File.join( __dir__, "../survey_v02/protocols.sql" ) )
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Survey scientific records require an explicit retention review"
  end
end
