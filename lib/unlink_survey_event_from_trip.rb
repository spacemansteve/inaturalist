# frozen_string_literal: true

class UnlinkSurveyEventFromTrip
  def self.call( event )
    event.with_lock( requires_new: true ) { event.update!( trip: nil ) }
    event
  end
end
