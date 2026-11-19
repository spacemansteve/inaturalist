# frozen_string_literal: true

class SurveyEventTarget < SurveyRecord
  belongs_to :survey_event
  belongs_to :survey_target
  belongs_to :taxon_snapshot, class_name: "Taxon", foreign_key: :taxon_id_snapshot, optional: true
  has_many :survey_detections, dependent: :restrict_with_error
  validates :survey_event, :survey_target, :target_label_snapshot, :target_scope_snapshot, presence: true
  validates :survey_target_id, uniqueness: { scope: :survey_event_id }
  validates :status, inclusion: { in: %w(not_assessed surveyed skipped not_applicable) }
  validate :absence_coverage

  private

  def absence_coverage
    errors.add( :absence_reporting, "requires a surveyed target and complete coverage" ) if
      absence_reporting && ( status != "surveyed" || coverage_complete != true )
  end
end
