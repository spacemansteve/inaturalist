# frozen_string_literal: true

class SurveySamplingUnit < SurveyRecord
  attribute( :geom ) {| type | Surveys::GeometryType.new( type ) }
  belongs_to :survey_site
  belongs_to :parent_survey_sampling_unit, class_name: "SurveySamplingUnit", optional: true
  has_many :child_sampling_units, class_name: "SurveySamplingUnit", foreign_key: :parent_survey_sampling_unit_id,
    dependent: :restrict_with_error
  has_many :survey_events, dependent: :restrict_with_error
  validates :survey_site, :code, presence: true
  validates :code, uniqueness: { scope: :survey_site_id }
  validates :unit_type, inclusion: { in: %w(point plot transect quadrat grid_cell route other) }
  validates :status, inclusion: { in: %w(active retired) }
  validates :area_square_meters, :length_meters, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :parent_site

  private

  def parent_site
    if parent_survey_sampling_unit &&
        ( parent_survey_sampling_unit_id == id || parent_survey_sampling_unit.survey_site_id != survey_site_id )
      errors.add( :parent_survey_sampling_unit, "must be another unit at the same site" )
    end
  end
end
