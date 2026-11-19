# frozen_string_literal: true

class SurveyProtocol < SurveyRecord
  belongs_to :user
  has_many :survey_protocol_versions, dependent: :restrict_with_error
  validates :user, :title, presence: true
  validates :status, inclusion: { in: %w(draft active archived) }
end
