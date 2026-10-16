# frozen_string_literal: true

class SurveyMeasurementDefinition < SurveyRecord
  belongs_to :survey_protocol_version
  has_many :survey_measurements, dependent: :restrict_with_error
  validates :survey_protocol_version, :label, :field_key, presence: true
  validates :field_key, format: { with: /\A[a-z][a-z0-9_]*\z/ },
    uniqueness: { scope: :survey_protocol_version_id }
  validates :data_type, inclusion: { in: %w(numeric text boolean categorical) }
  validates :applies_to, inclusion: { in: %w(event detection) }
  validate :valid_configuration

  private

  def valid_configuration
    errors.add( :validation_rules, "unsupported rules or categorical values" ) unless
      database_rule_valid?( "survey_valid_measurement_definition", data_type, allowed_values.to_json,
        validation_rules.to_json )
    errors.add( :survey_protocol_version, "must be a draft" ) if survey_protocol_version &&
      survey_protocol_version.status != "draft"
  end
end
