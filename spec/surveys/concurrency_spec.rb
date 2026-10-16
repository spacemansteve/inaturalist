# frozen_string_literal: true

require_relative "survey_spec_helper"
require "timeout"

RSpec.describe "Concurrent survey writes", :survey_concurrency do
  before do
    skip "Run concurrency specs separately in inaturalist_survey_v02_test" unless
      ActiveRecord::Base.connection_db_config.database == "inaturalist_survey_v02_test"
    @concurrency_cleanup = true
  end

  after do
    next unless @concurrency_cleanup

    # Only this dedicated test database, only these new tables, no CASCADE and
    # no legacy-data cleanup. Other examples use rollback-only transactions.
    tables = %w(survey_measurements survey_observations survey_detections survey_efforts survey_event_participants
                survey_event_targets survey_events survey_sampling_units survey_sites survey_measurement_definitions
                survey_targets survey_protocol_versions survey_protocols)
    sql "TRUNCATE #{tables.join( ',' )}"
    sql "DELETE FROM users WHERE id=#{@survey_user.id}" if @survey_user
  end

  # The second connection must demonstrably be waiting on the first transaction
  # before it is released. Timing sleeps alone cannot establish that a race ran.
  def race( first_sql, second_sql )
    locked = Queue.new
    release = Queue.new
    second_pid = Queue.new
    workers = []
    workers << Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do | conn |
        conn.transaction do
          conn.execute( first_sql )
          locked << true
          release.pop
        end
      end
      :committed
    rescue StandardError => e
      locked << e
      e
    end
    acquired = Timeout.timeout( 10 ) { locked.pop }
    raise acquired if acquired.is_a?( Exception )

    workers << Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do | conn |
        second_pid << conn.raw_connection.backend_pid
        conn.transaction { conn.execute( second_sql ) }
      end
      :committed
    rescue StandardError => e
      e
    end
    pid = Timeout.timeout( 10 ) { second_pid.pop }
    Timeout.timeout( 10 ) do
      loop do
        break if ActiveRecord::Base.connection.select_value( "SELECT cardinality(pg_blocking_pids(#{pid})) > 0" )
        raise "Second writer did not block" unless workers.last.alive?

        sleep 0.01
      end
    end
    release << true
    Timeout.timeout( 10 ) { workers.map( &:value ) }
  ensure
    release << true
    workers.each {| worker | worker.join( 10 ) }
  end

  it "serializes publication against target edits" do
    v = draft_version
    t = target_for( v )
    results = race(
      "UPDATE survey_protocol_versions SET status='published',published_at=now() WHERE id=#{v.id}",
      "UPDATE survey_targets SET label='Changed concurrently' WHERE id=#{t.id}"
    )
    expect( results.first ).to eq :committed
    expect( results.last ).to be_a ActiveRecord::StatementInvalid
    expect( t.reload.label ).to eq "Birds"
  end

  it "validates publication after a concurrent deletion of the last draft target" do
    v = draft_version
    t = target_for( v )
    results = race(
      "DELETE FROM survey_targets WHERE id=#{t.id}",
      "UPDATE survey_protocol_versions SET status='published',published_at=now() WHERE id=#{v.id}"
    )
    expect( results.last ).to be_a ActiveRecord::StatementInvalid
    expect( v.reload.status ).to eq "draft"
  end

  it "prevents opposite sampling-unit edges from forming a cycle" do
    site = SurveySite.create!( name: "Race site", created_by_user: survey_user )
    a, b = %w(A B).map {| code | site.survey_sampling_units.create!( code: code, unit_type: "point" ) }
    results = race(
      "UPDATE survey_sampling_units SET parent_survey_sampling_unit_id=#{b.id} WHERE id=#{a.id}",
      "UPDATE survey_sampling_units SET parent_survey_sampling_unit_id=#{a.id} WHERE id=#{b.id}"
    )
    expect( results.last ).to be_a ActiveRecord::StatementInvalid
    expect( b.reload.parent_survey_sampling_unit_id ).to be_nil
  end

  it "freezes child writes that race with completion" do
    e = CreateSurveyEvent.call( protocol_version: published_version, user: survey_user, started_at: Time.current )
    e.survey_event_targets.first.update!( status: "surveyed" )
    effort = e.survey_efforts.create!( method: "point_count", duration_seconds: 600 )
    results = race(
      "UPDATE survey_events SET status='completed', completed_at=now() WHERE id=#{e.id}",
      "UPDATE survey_efforts SET duration_seconds=1 WHERE id=#{effort.id}"
    )
    expect( results.first ).to eq :committed
    expect( results.last ).to be_a ActiveRecord::StatementInvalid
    expect( effort.reload.duration_seconds ).to eq 600
  end

  it "rechecks completion after a concurrent removal of required effort" do
    e = CreateSurveyEvent.call( protocol_version: published_version, user: survey_user, started_at: Time.current )
    e.survey_event_targets.first.update!( status: "surveyed" )
    effort = e.survey_efforts.create!( method: "point_count", duration_seconds: 600 )
    results = race(
      "DELETE FROM survey_efforts WHERE id=#{effort.id}",
      "UPDATE survey_events SET status='completed', completed_at=now() WHERE id=#{e.id}"
    )
    expect( results.last ).to be_a ActiveRecord::StatementInvalid
    expect( e.reload.status ).to eq "planned"
  end

  it "serializes simultaneous publication attempts" do
    version = draft_version
    target_for( version )
    publish = "UPDATE survey_protocol_versions SET status='published',published_at=clock_timestamp() " \
      "WHERE id=#{version.id}"
    results = race( publish, publish )
    expect( results.first ).to eq :committed
    expect( results.last ).to be_a ActiveRecord::StatementInvalid
    expect( version.reload.status ).to eq "published"
  end

  it "serializes simultaneous completion attempts" do
    event = CreateSurveyEvent.call( protocol_version: published_version, user: survey_user, started_at: Time.current )
    event.survey_event_targets.first.update!( status: "surveyed" )
    event.survey_efforts.create!( method: "point_count" )
    complete = "UPDATE survey_events SET status='completed',completed_at=clock_timestamp() WHERE id=#{event.id}"
    results = race( complete, complete )
    expect( results.first ).to eq :committed
    expect( results.last ).to be_a ActiveRecord::StatementInvalid
    expect( event.reload.status ).to eq "completed"
  end

  it "prevents opposite event edges from forming a cycle" do
    version = published_version
    a, b = 2.times.map { CreateSurveyEvent.call( protocol_version: version, user: survey_user ) }
    results = race(
      "UPDATE survey_events SET parent_survey_event_id=#{b.id} WHERE id=#{a.id}",
      "UPDATE survey_events SET parent_survey_event_id=#{a.id} WHERE id=#{b.id}"
    )
    expect( results.last ).to be_a ActiveRecord::StatementInvalid
    expect( b.reload.parent_survey_event_id ).to be_nil
  end

  it "deduplicates simultaneous ingestion attempts without taxon uniqueness" do
    e = CreateSurveyEvent.call( protocol_version: published_version, user: survey_user )
    insert = "INSERT INTO survey_detections(uuid,survey_event_id,created_at,updated_at) VALUES " \
      "('#{SecureRandom.uuid}',#{e.id},now(),now())"
    results = race( insert, insert )
    expect( results.first ).to eq :committed
    expect( results.last ).to be_a ActiveRecord::RecordNotUnique
    expect( e.survey_detections.count ).to eq 1
  end
end
