# frozen_string_literal: true

class SurveySite < SurveyRecord
  attribute( :geom ) {| type | Surveys::GeometryType.new( type ) }
  belongs_to :place, optional: true
  belongs_to :created_by_user, class_name: "User"
  has_many :survey_sampling_units, dependent: :restrict_with_error
  has_many :survey_events, dependent: :restrict_with_error
  validates :name, :created_by_user, presence: true
  validates :location_privacy, inclusion: { in: %w(public restricted private) }
end
