# frozen_string_literal: true

class CreateSurveyResults < ActiveRecord::Migration[6.1]
  def up
    create_table :survey_detections do | t |
      # Clients reuse this UUID on ingestion retries; independent detections use
      # distinct UUIDs, even for the same event and taxon.
      t.uuid :uuid, null: false, default: -> { "uuid_generate_v4()" }
      t.references :survey_event, null: false, foreign_key: true, index: false
      t.bigint :survey_event_target_id
      t.integer :taxon_id
      t.text :taxon_name_snapshot
      t.text :external_taxon_uri
      t.string :occurrence_status, null: false, default: "present"
      t.decimal :quantity
      t.text :quantity_type
      t.text :quantity_verbatim
      t.datetime :recorded_at
      t.bigint :survey_effort_id
      t.integer :recorded_by_user_id
      t.text :remarks
      t.timestamps
    end
    add_index :survey_detections, :uuid, unique: true
    add_index :survey_detections, [:survey_event_id, :survey_event_target_id], name: "survey_detections_event_target"
    add_index :survey_detections, :survey_event_target_id, name: "survey_detections_target"
    add_index :survey_detections, :survey_effort_id
    add_index :survey_detections, :taxon_id
    add_index :survey_detections, :recorded_by_user_id
    add_index :survey_detections, [:id, :survey_event_id], unique: true, name: "survey_detection_event_pair"
    add_foreign_key :survey_detections, :taxa
    add_foreign_key :survey_detections, :users, column: :recorded_by_user_id
    add_check_constraint :survey_detections, "occurrence_status IN ('present','absent')",
      name: "survey_detection_occurrence"
    add_check_constraint :survey_detections, "quantity >= 0 AND quantity <> 'NaN'::numeric",
      name: "survey_detection_quantity"
    add_check_constraint :survey_detections,
      "occurrence_status <> 'absent' OR (survey_event_target_id IS NOT NULL AND (quantity IS NULL OR " \
        "quantity = 0) AND quantity_verbatim IS NULL)",
      name: "survey_absence_quantity"
    execute <<~SQL
      ALTER TABLE survey_detections ADD CONSTRAINT survey_detection_target_event_fk
        FOREIGN KEY (survey_event_target_id, survey_event_id) REFERENCES survey_event_targets (id, survey_event_id);
      ALTER TABLE survey_detections ADD CONSTRAINT survey_detection_effort_event_fk
        FOREIGN KEY (survey_effort_id, survey_event_id) REFERENCES survey_efforts (id, survey_event_id);
    SQL

    create_table :survey_observations do | t |
      t.references :survey_event, null: false, foreign_key: true, index: false
      t.integer :observation_id, null: false
      t.bigint :survey_detection_id
      t.timestamps
    end
    add_index :survey_observations, [:survey_event_id, :observation_id], unique: true, name: "survey_observation_unique"
    add_index :survey_observations, :observation_id
    add_index :survey_observations, :survey_detection_id
    # Removing a source Observation removes only this optional evidence link.
    add_foreign_key :survey_observations, :observations, on_delete: :cascade
    execute <<~SQL
      ALTER TABLE survey_observations ADD CONSTRAINT survey_observation_detection_event_fk
        FOREIGN KEY (survey_detection_id, survey_event_id) REFERENCES survey_detections (id, survey_event_id);
    SQL

    create_table :survey_measurements do | t |
      t.references :survey_event, null: false, foreign_key: true, index: false
      t.bigint :survey_detection_id
      t.references :survey_measurement_definition, null: false, foreign_key: true,
        index: { name: "survey_measurements_definition" }
      t.decimal :value_numeric
      t.text :value_text
      t.boolean :value_boolean
      t.string :unit
      t.datetime :recorded_at
      t.timestamps
    end
    add_index :survey_measurements, [:survey_event_id, :survey_measurement_definition_id],
      name: "survey_measurements_event_definition"
    add_index :survey_measurements, :survey_detection_id
    add_check_constraint :survey_measurements,
      "num_nonnulls(value_numeric,value_text,value_boolean) = 1 AND (value_numeric IS NULL OR " \
        "value_numeric <> 'NaN'::numeric)",
      name: "survey_measurement_one_value"
    execute <<~SQL
      ALTER TABLE survey_measurements ADD CONSTRAINT survey_measurement_detection_event_fk
        FOREIGN KEY (survey_detection_id, survey_event_id) REFERENCES survey_detections (id, survey_event_id);
    SQL
    execute File.read( File.join( __dir__, "../survey_v02/results.sql" ) )
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Survey scientific records require an explicit retention review"
  end
end
