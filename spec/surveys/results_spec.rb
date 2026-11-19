# frozen_string_literal: true

require_relative "survey_spec_helper"

RSpec.describe "Survey scientific results" do
  let( :event ) { CreateSurveyEvent.call( protocol_version: published_version, user: survey_user ) }
  let( :target ) { event.survey_event_targets.first }
  let( :effort ) { event.survey_efforts.create!( method: "point_count", duration_seconds: 600 ) }

  def enable_absence
    effort
    target.update!( status: "surveyed", coverage_complete: true, absence_reporting: true )
  end

  it "records independent counts, qualitative detections and explicit non-detections" do
    enable_absence
    2.times { event.survey_detections.create!( survey_event_target: target, quantity: 2 ) }
    event.survey_detections.create!( quantity_verbatim: "5–10" )
    absent = event.survey_detections.create!( survey_event_target: target, occurrence_status: "absent", quantity: 0 )
    expect( event.survey_detections.count ).to eq 4
    expect( absent.quantity ).to eq 0
    expect( event.survey_detections.where.not( quantity_verbatim: nil ).first.quantity ).to be_nil
    rejects_sql "UPDATE survey_detections SET quantity=1 WHERE id=#{absent.id}"
    rejects_sql "UPDATE survey_detections SET quantity_verbatim='several' WHERE id=#{absent.id}"
  end

  it "does not infer absence from unassessed, skipped or incomplete targets" do
    effort
    %w(not_assessed skipped not_applicable surveyed).each do | status |
      target.update!( status: status, coverage_complete: false )
      expect( event.survey_detections.build( occurrence_status: "absent",
        survey_event_target: target ) ).not_to be_valid
      rejects_sql "UPDATE survey_event_targets SET absence_reporting=true WHERE id=#{target.id}"
    end
    expect( event.survey_detections.count ).to eq 0
  end

  it "requires positive effort and protects the context of existing absences" do
    zero = event.survey_efforts.create!( method: "point_count", duration_seconds: 0 )
    rejects_sql "UPDATE survey_event_targets SET status='surveyed', coverage_complete=true, " \
      "absence_reporting=true WHERE id=#{target.id}"
    enable_absence
    absent = event.survey_detections.create!( occurrence_status: "absent", survey_event_target: target )
    rejects_sql "UPDATE survey_efforts SET duration_seconds=0 WHERE id=#{effort.id}"
    rejects_sql "DELETE FROM survey_efforts WHERE id=#{effort.id}"
    rejects_sql "UPDATE survey_event_targets SET absence_reporting=false WHERE id=#{target.id}"
    expect( absent.reload.quantity ).to be_nil
    expect( zero.reload.duration_seconds ).to eq 0
  end

  it "enforces same-event target and effort links with composite foreign keys" do
    other = CreateSurveyEvent.call( protocol_version: event.survey_protocol_version, user: survey_user )
    detection = other.survey_detections.create!
    rejects_sql "UPDATE survey_detections SET survey_event_target_id=#{target.id} WHERE id=#{detection.id}"
    rejects_sql "UPDATE survey_detections SET survey_effort_id=#{effort.id} WHERE id=#{detection.id}"
  end

  it "deduplicates ingestion UUIDs without forbidding repeated taxa" do
    detection = event.survey_detections.create!( uuid: SecureRandom.uuid )
    duplicate = detection.attributes.except( "id" )
    expect do
      ActiveRecord::Base.transaction( requires_new: true ) { SurveyDetection.insert_all!( [duplicate] ) }
    end.to raise_error( ActiveRecord::RecordNotUnique )
    expect( event.survey_detections.count ).to eq 1
  end

  it "supports multiple observation contexts and controlled unlinking" do
    attributes = { user_id: survey_user.id, created_at: Time.current, updated_at: Time.current }
    observation = Observation.find( Observation.insert_all!( [attributes] ).rows.first.first )
    other = CreateSurveyEvent.call( protocol_version: event.survey_protocol_version, user: survey_user )
    detection = event.survey_detections.create!
    link = event.survey_observations.create!( observation: observation, survey_detection: detection )
    other_link = other.survey_observations.create!( observation: observation )
    expect( SurveyObservation.where( observation: observation ).count ).to eq 2
    expect( other.survey_observations.build( observation: observation, survey_detection: detection ) ).not_to be_valid
    rejects_sql "INSERT INTO survey_observations(survey_event_id, observation_id, survey_detection_id, " \
      "created_at, updated_at) VALUES (#{other.id}, #{observation.id}, #{detection.id}, now(), now())"
    UnlinkSurveyObservation.call( link )
    expect( Observation.exists?( observation.id ) ).to be true
    expect( SurveyDetection.exists?( detection.id ) ).to be true
    sql "DELETE FROM observations WHERE id=#{observation.id}"
    expect( SurveyObservation.exists?( other_link.id ) ).to be false
    expect( SurveyEvent.exists?( event.id ) ).to be true
  end

  it "validates numeric, categorical, boolean and text values and their versioned semantics" do
    version = draft_version
    target_for( version )
    fields = {
      "numeric" => { unit: "C", validation_rules: { min: -20, max: 50 } },
      "categorical" => { allowed_values: %w(clear cloudy) }, "boolean" => {}, "text" => {}
    }.map do | kind, attrs |
      version.survey_measurement_definitions.create!( { field_key: kind, label: kind, data_type: kind }.merge( attrs ) )
    end
    PublishSurveyProtocolVersion.call( version )
    e = CreateSurveyEvent.call( protocol_version: version, user: survey_user )
    values = [{ value_numeric: 20, unit: "C" }, { value_text: "clear" }, { value_boolean: false },
              { value_text: "Breeze" }]
    measurements = fields.zip( values ).map do | field, attrs |
      e.survey_measurements.create!( attrs.merge( survey_measurement_definition: field ) )
    end
    numeric, category, boolean = measurements
    expect( boolean.reload.value_boolean ).to be false
    rejects_sql "UPDATE survey_measurements SET value_numeric=70 WHERE id=#{numeric.id}"
    rejects_sql "UPDATE survey_measurements SET unit='F' WHERE id=#{numeric.id}"
    rejects_sql "UPDATE survey_measurements SET value_text='rain' WHERE id=#{category.id}"
    rejects_sql "UPDATE survey_measurements SET value_numeric=1 WHERE id=#{boolean.id}"
    rejects_sql "UPDATE survey_measurements SET value_boolean=NULL WHERE id=#{boolean.id}"
    rejects_sql "UPDATE survey_measurements SET value_numeric=NULL,value_text='20' WHERE id=#{numeric.id}"
    rejects_sql "UPDATE survey_measurements SET value_numeric='NaN' WHERE id=#{numeric.id}"
    expect( event.survey_measurements.build( survey_measurement_definition: fields.first, value_numeric: 20,
      unit: "C" ) ).not_to be_valid
    rejects_sql <<~SQL
      INSERT INTO survey_measurements
        (survey_event_id,survey_measurement_definition_id,value_numeric,unit,created_at,updated_at)
        VALUES (#{event.id},#{fields.first.id},20,'C',now(),now())
    SQL
  end
end
