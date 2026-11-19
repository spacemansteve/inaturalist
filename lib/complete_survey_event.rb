# frozen_string_literal: true

class CompleteSurveyEvent
  def self.call( event )
    event.with_lock( requires_new: true ) do
      raise ArgumentError, "Only planned or in-progress surveys can be completed" unless
        %w(planned in_progress).include?( event.status )

      event.errors.clear
      query = "SELECT to_json(survey_completion_errors(e))::text FROM survey_events e WHERE id = ?"
      messages = SurveyEvent.connection.select_value( SurveyEvent.sanitize_sql_array( [query, event.id] ) )
      JSON.parse( messages ).each {| message | event.errors.add( :base, message ) }
      raise ActiveRecord::RecordInvalid, event if event.errors.any?

      event.update!( status: "completed", completed_at: Time.current )
    end
    event.reload
  end
end
