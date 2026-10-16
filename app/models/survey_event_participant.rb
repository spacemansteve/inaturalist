# frozen_string_literal: true

class SurveyEventParticipant < SurveyRecord
  belongs_to :survey_event
  belongs_to :user, optional: true
  validates :survey_event, presence: true
  validates :participant_name, presence: true, unless: :user_id?
  validates :user_id, uniqueness: { scope: :survey_event_id }, allow_nil: true
  validates :role, inclusion: { in: %w(observer leader recorder validator other) }
end
