# frozen_string_literal: true

class SurveyProtocolVersion < SurveyRecord
  belongs_to :survey_protocol
  has_many :survey_targets, dependent: :restrict_with_error
  has_many :survey_measurement_definitions, dependent: :restrict_with_error
  has_many :survey_events, dependent: :restrict_with_error
  validates :survey_protocol, presence: true
  validates :version_number, numericality: { only_integer: true, greater_than: 0 },
    uniqueness: { scope: :survey_protocol_id }
  validates :status, inclusion: { in: %w(draft published retired) }
  validate :valid_definition
  validate :preserve_published_definition

  private

  def valid_definition
    errors.add( :definition, "contains unsupported configuration" ) unless
      database_rule_valid?( "survey_valid_protocol_definition", definition.to_json )
  end

  def preserve_published_definition
    return unless persisted? && published_at_in_database
    return if ( changes.keys - %w(status updated_at) ).empty? &&
      ( status == status_in_database || ( status_in_database == "published" && status == "retired" ) )

    errors.add( :base, "Published scientific definitions are immutable" )
  end
end
