# frozen_string_literal: true

class SurveyEffort < SurveyRecord
  belongs_to :survey_event
  has_many :survey_detections, dependent: :restrict_with_error
  validates :survey_event, :method, presence: true
  validates :duration_seconds, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :distance_meters, :area_square_meters, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :observer_count, :replicate_number, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :valid_timing

  private

  def valid_timing
    errors.add( :ended_at, "must not precede start" ) if ended_at && ( started_at.nil? || ended_at < started_at )
  end
end
