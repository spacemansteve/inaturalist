# frozen_string_literal: true

class EnforceSurveyCompletion < ActiveRecord::Migration[6.1]
  def up
    execute File.read( File.join( __dir__, "../survey_v02/completion.sql" ) )
    {
      survey_sampling_units: [:area_square_meters, :length_meters],
      survey_efforts: [:distance_meters, :area_square_meters],
      survey_detections: [:quantity],
      survey_measurements: [:value_numeric]
    }.each do | table, columns |
      columns.each do | column |
        add_check_constraint table, "#{column} NOT IN ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric)",
          name: "#{table}_#{column}_finite"
      end
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Survey scientific records require an explicit retention review"
  end
end
