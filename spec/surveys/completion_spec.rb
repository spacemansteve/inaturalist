# frozen_string_literal: true

require_relative "survey_spec_helper"

RSpec.describe "Survey completion and history" do
  let( :version ) do
    v = draft_version
    target_for( v )
    v.update!( definition: { allowed_methods: ["point_count"], required_effort_fields: ["duration_seconds"] } )
    v.survey_measurement_definitions.create!( field_key: "temperature", label: "Air temperature",
      data_type: "numeric", unit: "C", required: true, validation_rules: { min: -40, max: 60 } )
    PublishSurveyProtocolVersion.call( v )
  end
  let( :site ) do
    SurveySite.create!( name: "Permanent monitoring site", created_by_user: survey_user, geom: "POINT(-71 42)" )
  end
  let( :unit ) { site.survey_sampling_units.create!( code: "A", unit_type: "point", geom: "POINT(-71 42)" ) }
  let( :event ) do
    CreateSurveyEvent.call( protocol_version: version, user: survey_user, survey_sampling_unit: unit,
      started_at: Time.utc( 2026, 10, 1, 10 ), ended_at: Time.utc( 2026, 10, 1, 10, 10 ), time_zone: "UTC" )
  end

  def ready( survey )
    survey.survey_efforts.create!( method: "point_count", duration_seconds: 600 )
    survey.survey_event_targets.each do | t |
      t.update!( status: "surveyed", coverage_complete: true, absence_reporting: true )
    end
    survey.survey_measurements.create!( survey_measurement_definition: version.survey_measurement_definitions.first,
      value_numeric: 20, unit: "C" )
  end

  it "checks completion only when finishing and never manufactures detections" do
    expect( event.status ).to eq "planned"
    expect { CompleteSurveyEvent.call( event ) }.to raise_error( ActiveRecord::RecordInvalid )
    rejects_sql "UPDATE survey_events SET status='completed', completed_at=now() WHERE id=#{event.id}"
    ready( event )
    expect( CompleteSurveyEvent.call( event ).status ).to eq "completed"
    expect( event.survey_detections.count ).to eq 0
    expect( event.completed_at ).to be_present
  end

  it "retains separate sampling snapshots across two completed visits" do
    ready( event )
    CompleteSurveyEvent.call( event )
    second = CreateSurveyEvent.call( protocol_version: version, user: survey_user, survey_sampling_unit: unit,
      started_at: Time.utc( 2026, 10, 2, 10 ), geom: "POINT(-71.001 42)" )
    ready( second )
    second.survey_event_targets.first.update!( coverage_complete: false, absence_reporting: false )
    second.update!( completion_status: "incomplete" )
    CompleteSurveyEvent.call( second )
    site.update!( geom: "POINT(-72 43)" )
    expect( event.reload.geom.x ).to eq( -71 )
    expect( second.reload.geom.x ).to eq( -71.001 )
    expect( unit.survey_events.order( :started_at ).pluck( :id ) ).to eq [event.id, second.id]
    rejects_sql "UPDATE survey_sampling_units SET geom=ST_GeomFromText('POINT(0 0)',4326) WHERE id=#{unit.id}"
    rejects_sql "UPDATE survey_sampling_units SET code='moved' WHERE id=#{unit.id}"
    unit.update!( status: "retired" )
  end

  it "freezes completed records, allows voiding, and never unlocks unit history" do
    ready( event )
    detection = event.survey_detections.create!( quantity: 1 )
    CompleteSurveyEvent.call( event )
    rejects_sql "DELETE FROM survey_events WHERE id=#{event.id}"
    rejects_sql "UPDATE survey_events SET geom=ST_GeomFromText('POINT(0 0)',4326) WHERE id=#{event.id}"
    rejects_sql "UPDATE survey_detections SET quantity=3 WHERE id=#{detection.id}"
    rejects_sql "DELETE FROM survey_efforts WHERE survey_event_id=#{event.id}"
    rejects_sql "UPDATE survey_event_targets SET remarks='rewrite' WHERE survey_event_id=#{event.id}"
    rejects_sql "DELETE FROM survey_sampling_units WHERE id=#{unit.id}"
    event.void!( reason: "Incorrect station; replacement visit recorded separately" )
    expect( event.reload.completed_at ).to be_present
    rejects_sql "UPDATE survey_sampling_units SET length_meters=12 WHERE id=#{unit.id}"
    rejects_sql "UPDATE survey_events SET status='planned',completed_at=NULL WHERE id=#{event.id}"
  end

  it "enforces detection-scoped required measurements" do
    v = draft_version
    target_for( v )
    definition = v.survey_measurement_definitions.create!( field_key: "stage", label: "Life stage",
      data_type: "categorical", applies_to: "detection", required: true, allowed_values: %w(adult juvenile) )
    PublishSurveyProtocolVersion.call( v )
    e = CreateSurveyEvent.call( protocol_version: v, user: survey_user, started_at: Time.current )
    e.survey_efforts.create!( method: "point_count" )
    e.survey_event_targets.first.update!( status: "surveyed" )
    detection = e.survey_detections.create!
    expect { CompleteSurveyEvent.call( e ) }.to raise_error( ActiveRecord::RecordInvalid, /detection measurements/ )
    m = e.survey_measurements.create!( survey_measurement_definition: definition, survey_detection: detection,
      value_text: "adult" )
    rejects_sql "UPDATE survey_measurements SET survey_detection_id=NULL WHERE id=#{m.id}"
    other_detection = event.survey_detections.create!
    rejects_sql "UPDATE survey_measurements SET survey_detection_id=#{other_detection.id} WHERE id=#{m.id}"
    CompleteSurveyEvent.call( e )
  end

  it "rejects skipped required targets unless the protocol explicitly permits them" do
    ready( event )
    event.survey_event_targets.first.update!( status: "skipped", absence_reporting: false )
    expect { CompleteSurveyEvent.call( event ) }.to raise_error( ActiveRecord::RecordInvalid, /Required targets/ )
    v = draft_version
    target_for( v )
    v.update!( definition: { allow_skipped_targets: true, require_effort: false } )
    PublishSurveyProtocolVersion.call( v )
    e = CreateSurveyEvent.call( protocol_version: v, user: survey_user, started_at: Time.current )
    e.survey_event_targets.first.update!( status: "skipped" )
    expect( CompleteSurveyEvent.call( e ).status ).to eq "completed"
  end

  it "does not allow retirement to rewrite or activate historical events" do
    ready( event )
    CompleteSurveyEvent.call( event )
    planned = CreateSurveyEvent.call( protocol_version: version, user: survey_user )
    version.update!( status: "retired" )
    expect( event.reload.survey_protocol_version_id ).to eq version.id
    rejects_sql "UPDATE survey_events SET status='in_progress' WHERE id=#{planned.id}"
    expect { CreateSurveyEvent.call( protocol_version: version, user: survey_user ) }.to raise_error( ArgumentError )
  end

  it "rejects timing edits that would exclude existing effort" do
    effort = event.survey_efforts.create!( method: "point_count", started_at: event.started_at,
      ended_at: event.ended_at )
    rejects_sql "UPDATE survey_events SET started_at='2026-10-01 10:05' WHERE id=#{event.id}"
    expect( effort.reload.started_at ).to eq event.started_at
  end
end
