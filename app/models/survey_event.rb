# frozen_string_literal: true

class SurveyEvent < SurveyRecord
  attribute( :geom ) {| type | Surveys::GeometryType.new( type ) }
  belongs_to :survey_protocol_version
  belongs_to :survey_site, optional: true
  belongs_to :survey_sampling_unit, optional: true
  belongs_to :trip, optional: true, inverse_of: :survey_events
  belongs_to :parent_survey_event, class_name: "SurveyEvent", optional: true
  belongs_to :user
  has_many :child_events, class_name: "SurveyEvent", foreign_key: :parent_survey_event_id,
    dependent: :restrict_with_error
  has_many :survey_event_targets, dependent: :restrict_with_error
  has_many :survey_event_participants, dependent: :restrict_with_error
  has_many :survey_efforts, dependent: :restrict_with_error
  has_many :survey_detections, dependent: :restrict_with_error
  has_many :survey_observations, dependent: :restrict_with_error
  has_many :survey_measurements, dependent: :restrict_with_error
  validates :survey_protocol_version, :user, presence: true
  validates :status, inclusion: { in: %w(planned in_progress completed void) }
  validates :completion_status, inclusion: { in: %w(complete incomplete unknown) }
  validates :location_privacy, inclusion: { in: %w(public restricted private) }
  validate :valid_timing_and_site

  def void!( reason: )
    with_lock( requires_new: true ) { update!( status: "void", voided_at: Time.current, void_reason: reason ) }
    self
  end

  private

  def valid_timing_and_site
    errors.add( :ended_at, "must not precede start" ) if ended_at && ( started_at.nil? || ended_at < started_at )
    errors.add( :started_at, "is required for completion" ) if status == "completed" && started_at.nil?
    errors.add( :survey_sampling_unit, "must belong to the event site" ) if survey_sampling_unit &&
      survey_sampling_unit.survey_site_id != survey_site_id
    errors.add( :time_zone, "must be a recognized time zone" ) if time_zone.present? &&
      ActiveSupport::TimeZone[time_zone].nil?
  end
end
