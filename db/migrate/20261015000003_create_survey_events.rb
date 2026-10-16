# frozen_string_literal: true

class CreateSurveyEvents < ActiveRecord::Migration[6.1]
  def up
    create_table :survey_events do | t |
      t.uuid :uuid, null: false, default: -> { "uuid_generate_v4()" }
      t.references :survey_protocol_version, null: false, foreign_key: true
      t.references :survey_site, foreign_key: true
      t.bigint :survey_sampling_unit_id
      t.integer :trip_id
      t.bigint :parent_survey_event_id
      t.integer :user_id, null: false
      t.datetime :started_at
      t.datetime :ended_at
      t.string :time_zone
      t.geometry :geom, srid: 4326
      t.string :location_privacy, null: false, default: "private"
      t.string :status, null: false, default: "planned"
      t.string :completion_status, null: false, default: "unknown"
      t.text :remarks
      t.datetime :completed_at
      t.datetime :voided_at
      t.text :void_reason
      t.timestamps
    end
    add_index :survey_events, :uuid, unique: true
    add_index :survey_events, :user_id
    add_index :survey_events, :trip_id
    add_index :survey_events, :parent_survey_event_id
    add_index :survey_events, [:survey_sampling_unit_id, :started_at], name: "survey_unit_history"
    add_index :survey_events, :geom, using: :gist
    add_foreign_key :survey_events, :users
    add_foreign_key :survey_events, :posts, column: :trip_id, on_delete: :nullify
    add_foreign_key :survey_events, :survey_events, column: :parent_survey_event_id
    execute <<~SQL
      ALTER TABLE survey_events ADD CONSTRAINT survey_event_unit_site_fk
        FOREIGN KEY (survey_sampling_unit_id, survey_site_id) REFERENCES survey_sampling_units (id, survey_site_id);
    SQL
    add_check_constraint :survey_events, "survey_sampling_unit_id IS NULL OR survey_site_id IS NOT NULL",
      name: "survey_event_unit_requires_site"
    add_check_constraint :survey_events, "ended_at IS NULL OR (started_at IS NOT NULL AND ended_at >= started_at)",
      name: "survey_event_times"
    add_check_constraint :survey_events,
      "status IN ('planned','in_progress','completed','void') AND completion_status IN " \
        "('complete','incomplete','unknown')",
      name: "survey_event_status"
    add_check_constraint :survey_events, "location_privacy IN ('public','restricted','private')",
      name: "survey_event_privacy"
    add_check_constraint :survey_events,
      "(status <> 'completed' OR (completed_at IS NOT NULL AND started_at IS NOT NULL)) AND (completed_at " \
        "IS NULL OR status IN ('completed','void')) AND (status <> 'void' OR (voided_at IS NOT NULL AND " \
        "NULLIF(btrim(void_reason),'') IS NOT NULL))",
      name: "survey_event_lifecycle"
    add_check_constraint :survey_events, <<~SQL.squish, name: "survey_events_geometry"
      geom IS NULL OR (ST_SRID(geom) = 4326 AND ST_IsValid(geom) AND NOT ST_IsEmpty(geom)
        AND GeometryType(geom) IN ('POINT','LINESTRING','POLYGON','MULTIPOINT','MULTILINESTRING','MULTIPOLYGON')
        AND ST_XMin(Box3D(geom)) >= -180 AND ST_XMax(Box3D(geom)) <= 180
        AND ST_YMin(Box3D(geom)) >= -90 AND ST_YMax(Box3D(geom)) <= 90)
    SQL

    create_table :survey_event_targets do | t |
      t.references :survey_event, null: false, foreign_key: true, index: false
      t.references :survey_target, null: false, foreign_key: true
      t.text :target_label_snapshot, null: false
      t.jsonb :target_scope_snapshot, null: false
      t.integer :taxon_id_snapshot
      t.text :taxon_name_snapshot
      t.text :external_taxon_uri_snapshot
      t.string :status, null: false, default: "not_assessed"
      t.boolean :coverage_complete
      t.boolean :absence_reporting
      t.text :remarks
      t.timestamps
    end
    add_index :survey_event_targets, [:survey_event_id, :survey_target_id], unique: true,
      name: "survey_event_target_unique"
    add_index :survey_event_targets, [:id, :survey_event_id], unique: true, name: "survey_target_event_pair"
    add_index :survey_event_targets, :taxon_id_snapshot
    add_foreign_key :survey_event_targets, :taxa, column: :taxon_id_snapshot
    add_check_constraint :survey_event_targets,
      "btrim(target_label_snapshot) <> '' AND jsonb_typeof(target_scope_snapshot) = 'object'",
      name: "survey_event_target_snapshot"
    add_check_constraint :survey_event_targets,
      "status IN ('not_assessed','surveyed','skipped','not_applicable')", name: "survey_event_target_status"
    add_check_constraint :survey_event_targets,
      "absence_reporting IS NOT TRUE OR (status = 'surveyed' AND coverage_complete IS TRUE)",
      name: "survey_target_absence_coverage"

    create_table :survey_event_participants do | t |
      t.references :survey_event, null: false, foreign_key: true, index: false
      t.integer :user_id
      t.text :participant_name
      t.string :role, null: false, default: "observer"
      t.timestamps
    end
    add_index :survey_event_participants, [:survey_event_id, :user_id], unique: true,
      name: "survey_registered_participant_unique"
    add_index :survey_event_participants, :user_id
    add_foreign_key :survey_event_participants, :users
    add_check_constraint :survey_event_participants,
      "user_id IS NOT NULL OR NULLIF(btrim(participant_name),'') IS NOT NULL", name: "survey_participant_identity"
    add_check_constraint :survey_event_participants,
      "role IN ('observer','leader','recorder','validator','other')", name: "survey_participant_role"

    create_table :survey_efforts do | t |
      t.references :survey_event, null: false, foreign_key: true
      t.string :method, null: false
      t.datetime :started_at
      t.datetime :ended_at
      t.integer :duration_seconds
      t.decimal :distance_meters
      t.decimal :area_square_meters
      t.integer :observer_count
      t.integer :replicate_number
      t.jsonb :equipment, null: false, default: {}
      t.jsonb :conditions, null: false, default: {}
      t.text :remarks
      t.timestamps
    end
    add_index :survey_efforts, [:id, :survey_event_id], unique: true, name: "survey_effort_event_pair"
    add_check_constraint :survey_efforts, "btrim(method) <> ''", name: "survey_effort_method"
    add_check_constraint :survey_efforts,
      "duration_seconds >= 0 AND distance_meters >= 0 AND distance_meters <> 'NaN'::numeric AND " \
        "area_square_meters >= 0 AND area_square_meters <> 'NaN'::numeric AND observer_count > 0 AND " \
        "replicate_number > 0",
      name: "survey_effort_quantities"
    add_check_constraint :survey_efforts, "ended_at IS NULL OR (started_at IS NOT NULL AND ended_at >= started_at)",
      name: "survey_effort_times"
    add_check_constraint :survey_efforts, "jsonb_typeof(equipment) = 'object' AND jsonb_typeof(conditions) = 'object'",
      name: "survey_effort_configuration"
    execute File.read( File.join( __dir__, "../survey_v02/events.sql" ) )
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Survey scientific records require an explicit retention review"
  end
end
