# frozen_string_literal: true

class CreateSurveySampling < ActiveRecord::Migration[6.1]
  def up
    create_table :survey_sites do | t |
      t.uuid :uuid, null: false, default: -> { "uuid_generate_v4()" }
      t.text :name, null: false
      t.text :description
      t.integer :place_id
      t.integer :created_by_user_id, null: false
      t.geometry :geom, srid: 4326
      t.string :location_privacy, null: false, default: "private"
      t.timestamps
    end
    add_index :survey_sites, :uuid, unique: true
    add_index :survey_sites, :place_id
    add_index :survey_sites, :created_by_user_id
    add_foreign_key :survey_sites, :places
    add_foreign_key :survey_sites, :users, column: :created_by_user_id
    add_check_constraint :survey_sites, "btrim(name) <> ''", name: "survey_site_name"
    add_check_constraint :survey_sites, "location_privacy IN ('public','restricted','private')",
      name: "survey_site_privacy"

    create_table :survey_sampling_units do | t |
      t.uuid :uuid, null: false, default: -> { "uuid_generate_v4()" }
      t.references :survey_site, null: false, foreign_key: true, index: false
      t.bigint :parent_survey_sampling_unit_id
      t.string :code, null: false
      t.text :name
      t.string :unit_type, null: false
      t.text :description
      t.geometry :geom, srid: 4326
      t.decimal :area_square_meters
      t.decimal :length_meters
      t.string :status, null: false, default: "active"
      t.timestamps
    end
    add_index :survey_sampling_units, :uuid, unique: true
    add_index :survey_sampling_units, [:survey_site_id, :code], unique: true, name: "survey_unit_code_unique"
    add_index :survey_sampling_units, [:id, :survey_site_id], unique: true, name: "survey_unit_site_unique"
    add_index :survey_sampling_units, :parent_survey_sampling_unit_id, name: "survey_unit_parent"
    add_check_constraint :survey_sampling_units, "btrim(code) <> ''", name: "survey_unit_code"
    add_check_constraint :survey_sampling_units,
      "unit_type IN ('point','plot','transect','quadrat','grid_cell','route','other') AND status IN " \
        "('active','retired')",
      name: "survey_unit_type_status"
    add_check_constraint :survey_sampling_units,
      "(area_square_meters >= 0 AND area_square_meters <> 'NaN'::numeric) AND (length_meters >= 0 AND " \
        "length_meters <> 'NaN'::numeric)",
      name: "survey_unit_dimensions"
    execute <<~SQL
      ALTER TABLE survey_sampling_units ADD CONSTRAINT survey_unit_parent_site_fk
        FOREIGN KEY (parent_survey_sampling_unit_id, survey_site_id)
        REFERENCES survey_sampling_units (id, survey_site_id);
    SQL
    [:survey_sites, :survey_sampling_units].each do | table |
      add_index table, :geom, using: :gist
      add_check_constraint table, <<~SQL.squish, name: "#{table}_geometry"
        geom IS NULL OR (ST_SRID(geom) = 4326 AND ST_IsValid(geom) AND NOT ST_IsEmpty(geom)
          AND GeometryType(geom) IN ('POINT','LINESTRING','POLYGON','MULTIPOINT','MULTILINESTRING','MULTIPOLYGON')
          AND ST_XMin(Box3D(geom)) >= -180 AND ST_XMax(Box3D(geom)) <= 180
          AND ST_YMin(Box3D(geom)) >= -90 AND ST_YMax(Box3D(geom)) <= 90)
      SQL
    end
    execute File.read( File.join( __dir__, "../survey_v02/sampling.sql" ) )
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Survey scientific records require an explicit retention review"
  end
end
