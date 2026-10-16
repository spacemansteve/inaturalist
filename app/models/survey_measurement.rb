# frozen_string_literal: true

class SurveyMeasurement < SurveyRecord
  belongs_to :survey_event
  belongs_to :survey_detection, optional: true
  belongs_to :survey_measurement_definition
  validates :survey_event, :survey_measurement_definition, presence: true
  validate :typed_value

  private

  def typed_value
    if [value_numeric, value_text, value_boolean].count {| v | !v.nil? } != 1
      errors.add( :base, "Exactly one typed measurement value is required" )
    end
    definition = survey_measurement_definition
    return unless definition && survey_event

    errors.add( :survey_measurement_definition, "must belong to the event protocol" ) if
      definition.survey_protocol_version_id != survey_event.survey_protocol_version_id
    errors.add( :survey_detection, "must belong to the same event" ) if survey_detection &&
      survey_detection.survey_event_id != survey_event_id
    if ( definition.applies_to == "detection" ) != survey_detection_id.present?
      errors.add( :survey_detection, "does not match the measurement scope" )
    end
    errors.add( :unit, "must match the definition" ) unless unit == definition.unit
    column = { "numeric" => :value_numeric, "text" => :value_text,
               "categorical" => :value_text, "boolean" => :value_boolean }[definition.data_type]
    errors.add( :base, "Value does not match the declared data type" ) if column && self[column].nil?
    if definition.data_type == "categorical" && !definition.allowed_values.include?( value_text )
      errors.add( :value_text, "is outside the defined vocabulary" )
    end
    return unless definition.data_type == "numeric" && value_numeric

    min, max = definition.validation_rules.values_at( "min", "max" )
    return unless ( min && value_numeric < min ) || ( max && value_numeric > max ) || !value_numeric.finite?

    errors.add( :value_numeric, "is outside the defined range" )
  end
end
