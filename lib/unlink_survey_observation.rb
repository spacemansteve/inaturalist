# frozen_string_literal: true

class UnlinkSurveyObservation
  def self.call( link )
    link.with_lock( requires_new: true ) { link.destroy! }
    link
  end
end
