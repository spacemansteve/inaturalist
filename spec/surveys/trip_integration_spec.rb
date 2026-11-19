# frozen_string_literal: true

require_relative "survey_spec_helper"

RSpec.describe "Structured surveys within legacy Trips" do
  let( :trip ) do
    # Persist a genuine STI Trip without invoking unrelated notification services.
    id = Post.insert_all!( [{ type: "Trip", user_id: survey_user.id, parent_id: survey_user.id,
                              parent_type: "User", title: "October visit", body: "Point counts",
                              start_time: Time.utc( 2026, 10, 1, 10 ), stop_time: Time.utc( 2026, 10, 1, 11 ),
                              created_at: Time.current, updated_at: Time.current }] ).rows.first.first
    Trip.find( id )
  end
  let( :version ) { published_version }
  let( :event ) do
    CreateSurveyEvent.call( protocol_version: version, trip: trip, user: survey_user, started_at: trip.start_time )
  end

  def observation( date )
    attributes = { user_id: survey_user.id, observed_on: date.to_date, time_observed_at: date,
                   created_at: Time.current, updated_at: Time.current }
    Observation.find( Observation.insert_all!( [attributes] ).rows.first.first )
  end

  def complete( survey )
    survey.survey_efforts.create!( method: "point_count", duration_seconds: 600 )
    survey.survey_event_targets.first.update!( status: "surveyed" )
    CompleteSurveyEvent.call( survey )
  end

  it "keeps implicit observations and explicit survey evidence independent" do
    implicit = observation( trip.start_time + 5.minutes )
    explicit = observation( trip.start_time + 3.days )
    original_query = trip.observations.to_sql
    event.survey_observations.create!( observation: explicit )
    expect( trip.observations.to_sql ).to eq original_query
    expect( trip.observations.pluck( :id ) ).to include implicit.id
    expect( trip.observations.pluck( :id ) ).not_to include explicit.id
    expect( trip.structured_survey_observations.pluck( :id ) ).to eq [explicit.id]
    expect( trip.trip_taxa.count ).to eq 0
    expect( trip.trip_purposes.count ).to eq 0
  end

  it "supports multiple protocols in one Trip and deduplicates shared observations" do
    second = CreateSurveyEvent.call( protocol_version: published_version, trip: trip, user: survey_user )
    o = observation( trip.start_time )
    [event, second].each {| e | e.survey_observations.create!( observation: o ) }
    expect( trip.survey_events.count ).to eq 2
    expect( trip.structured_survey_observations.pluck( :id ) ).to eq [o.id]
  end

  it "allows unlinking Trip and Observation evidence after completion without losing scientific records" do
    o = observation( trip.start_time )
    detection = event.survey_detections.create!( quantity: 1 )
    link = event.survey_observations.create!( observation: o, survey_detection: detection )
    complete( event )
    UnlinkSurveyEventFromTrip.call( event )
    UnlinkSurveyObservation.call( link )
    expect( event.reload.trip_id ).to be_nil
    expect( event.status ).to eq "completed"
    expect( event.survey_detections.first ).to eq detection
    expect( event.survey_efforts.count ).to eq 1
    expect( Observation.exists?( o.id ) ).to be true
    expect( Trip.exists?( trip.id ) ).to be true
  end

  it "nullifies on Trip deletion and removes only evidence when an Observation is deleted" do
    o = observation( trip.start_time )
    event.survey_observations.create!( observation: o )
    complete( event )
    sql "DELETE FROM posts WHERE id=#{trip.id}"
    sql "DELETE FROM observations WHERE id=#{o.id}"
    expect( event.reload.trip_id ).to be_nil
    expect( event.survey_observations.count ).to eq 0
    expect( event.survey_efforts.count ).to eq 1
  end

  it "enforces Trip STI in both directions" do
    event
    rejects_sql "UPDATE posts SET type=NULL WHERE id=#{trip.id}"
    attributes = { user_id: survey_user.id, parent_id: survey_user.id, parent_type: "User",
                   title: "Journal", created_at: Time.current, updated_at: Time.current }
    post = Post.insert_all!( [attributes] ).rows.first.first
    rejects_sql "UPDATE survey_events SET trip_id=#{post} WHERE id=#{event.id}"
  end
end
