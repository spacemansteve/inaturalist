# frozen_string_literal: true

class SurveyDetection < SurveyRecord
  belongs_to :survey_event
  belongs_to :survey_event_target, optional: true
  belongs_to :survey_effort, optional: true
  belongs_to :taxon, optional: true
  belongs_to :recorded_by_user, class_name: "User", optional: true
  has_many :survey_observations, dependent: :restrict_with_error
  has_many :survey_measurements, dependent: :restrict_with_error
  before_validation :snapshot_taxon_name, on: :create
  validates :survey_event, presence: true
  validates :occurrence_status, inclusion: { in: %w(present absent) }
  validates :quantity, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :valid_context

  private

  def snapshot_taxon_name
    self.taxon_name_snapshot ||= taxon&.name
  end

  def valid_context
    [survey_event_target, survey_effort].compact.each do | record |
      errors.add( :survey_event, "must match the target and effort" ) if record.survey_event_id != survey_event_id
    end
    return unless occurrence_status == "absent"

    if quantity.to_f > 0 || quantity_verbatim.present?
      errors.add( :quantity, "a non-detection cannot carry positive or qualitative counts" )
    end
    unless survey_event_target&.status == "surveyed" && survey_event_target.coverage_complete == true &&
        survey_event_target.absence_reporting == true
      errors.add( :survey_event_target, "must permit absence reporting with complete coverage" )
    end
  end
end
