# frozen_string_literal: true

class CreateSurveyEvent
  def self.call( protocol_version:, **attributes )
    SurveyEvent.transaction( requires_new: true ) do
      protocol_version.lock!
      raise ArgumentError, "A published protocol is required" unless protocol_version.status == "published"

      unit = attributes[:survey_sampling_unit]
      unit ||= SurveySamplingUnit.find( attributes[:survey_sampling_unit_id] ) if attributes[:survey_sampling_unit_id]
      if unit
        unit.lock!
        attributes[:survey_site_id] ||= attributes[:survey_site]&.id || unit.survey_site_id
        attributes[:geom] = unit.geom unless attributes.key?( :geom )
      end
      site = attributes[:survey_site] || SurveySite.find_by( id: attributes[:survey_site_id] )
      attributes[:location_privacy] ||= site&.location_privacy || "private"
      event = SurveyEvent.create!( attributes.merge( survey_protocol_version: protocol_version ) )
      protocol_version.survey_targets.order( :id ).each do | target |
        event.survey_event_targets.create!( survey_target: target,
          target_label_snapshot: target.label,
          target_scope_snapshot: { scope_type: target.scope_type, scope_definition: target.scope_definition },
          taxon_id_snapshot: target.taxon_id, taxon_name_snapshot: target.taxon_name_snapshot,
          external_taxon_uri_snapshot: target.external_taxon_uri )
      end
      event.reload
    end
  end
end
