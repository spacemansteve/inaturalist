# frozen_string_literal: true

require_relative "survey_spec_helper"

RSpec.describe "Survey initialization" do
  let( :version ) { published_version }
  let( :event ) { CreateSurveyEvent.call( protocol_version: version, user: survey_user ) }

  it "copies every published target, including scope and taxon snapshots" do
    target = event.survey_event_targets.first
    expect( target.target_scope_snapshot ).to eq( "scope_type" => "taxon_group",
      "scope_definition" => { "description" => "All birds detected at the point" } )
    expect( target.status ).to eq "not_assessed"
    expect( target.absence_reporting ).to be_nil
  end

  it "rolls back the whole event when snapshot creation fails" do
    allow_any_instance_of( SurveyEventTarget ).to receive( :save! ).and_raise( ActiveRecord::RecordInvalid )
    expect do
      expect { event }.to raise_error( ActiveRecord::RecordInvalid )
    end.not_to change( SurveyEvent, :count )
  end

  it "rejects another version's target, even through SQL" do
    other = published_version.survey_targets.first
    target = event.survey_event_targets.first
    rejects_sql "UPDATE survey_event_targets SET survey_target_id=#{other.id} WHERE id=#{target.id}"
    rejects_sql "UPDATE survey_event_targets SET target_label_snapshot='Changed' WHERE id=#{target.id}"
  end

  it "rejects invalid absence assessments" do
    target = event.survey_event_targets.first
    rejects_sql "UPDATE survey_event_targets SET absence_reporting=true WHERE id=#{target.id}"
    expect( target.update( absence_reporting: true ) ).to be false
  end

  it "supports named historical participants and rejects duplicates" do
    event.survey_event_participants.create!( participant_name: "Historical observer" )
    event.survey_event_participants.create!( user: survey_user )
    expect( event.survey_event_participants.build( user: survey_user ) ).not_to be_valid
    expect( event.survey_event_participants.build ).not_to be_valid
  end

  it "enforces method configuration and event timing" do
    draft = draft_version
    target_for( draft )
    draft.update!( definition: { allowed_methods: ["point_count"] } )
    PublishSurveyProtocolVersion.call( draft )
    e = CreateSurveyEvent.call( protocol_version: draft, user: survey_user,
      started_at: Time.utc( 2026, 10, 1, 10 ), ended_at: Time.utc( 2026, 10, 1, 11 ) )
    effort = e.survey_efforts.create!( method: "point_count", duration_seconds: 0 )
    rejects_sql "UPDATE survey_efforts SET method='other' WHERE id=#{effort.id}"
    rejects_sql "UPDATE survey_efforts SET started_at='2026-10-01 09:00:00' WHERE id=#{effort.id}"
    expect( effort.reload.duration_seconds ).to eq 0
    expect( effort.distance_meters ).to be_nil
  end

  it "rejects event cycles and drafts" do
    child = CreateSurveyEvent.call( protocol_version: version, user: survey_user, parent_survey_event: event )
    rejects_sql "UPDATE survey_events SET parent_survey_event_id=#{child.id} WHERE id=#{event.id}"
    expect do
      CreateSurveyEvent.call( protocol_version: draft_version, user: survey_user )
    end.to raise_error( ArgumentError )
  end
end
