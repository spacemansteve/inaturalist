# frozen_string_literal: true

class SurveyObservation < SurveyRecord
  belongs_to :survey_event
  belongs_to :observation
  belongs_to :survey_detection, optional: true
  validates :survey_event, :observation, presence: true
  validates :observation_id, uniqueness: { scope: :survey_event_id }
  validate :detection_event

  private

  def detection_event
    errors.add( :survey_detection, "must belong to the same event" ) if survey_detection &&
      survey_detection.survey_event_id != survey_event_id
  end
end
