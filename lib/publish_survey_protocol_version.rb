# frozen_string_literal: true

class PublishSurveyProtocolVersion
  def self.call( version )
    version.with_lock( requires_new: true ) do
      unless version.status == "draft"
        raise ArgumentError, "Only a draft version can be published"
      end

      version.validate!
      version.survey_targets.each( &:validate! )
      version.survey_measurement_definitions.each( &:validate! )
      if version.survey_targets.empty?
        version.errors.add( :survey_targets, "must contain at least one target" )
        raise ActiveRecord::RecordInvalid, version
      end
      version.update!( status: "published", published_at: Time.current )
    end
    version
  end
end
