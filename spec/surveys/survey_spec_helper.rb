# frozen_string_literal: true

# Database-only survey tests intentionally do not load spec_helper, whose suite
# hooks truncate every table and rebuild Elasticsearch and Qdrant indexes.
ENV["RAILS_ENV"] = "test"
require File.expand_path( "../../config/environment", __dir__ )
require "rspec/rails"
raise "Survey tests require a test database" unless Rails.env.test? &&
  ActiveRecord::Base.connection_db_config.database.match?( /test/ )

module SurveySpecHelpers
  def sql( statement )
    ActiveRecord::Base.connection.execute( statement )
  end

  def rejects_sql( statement )
    expect do
      ActiveRecord::Base.transaction( requires_new: true ) { sql( statement ) }
    end.to raise_error( ActiveRecord::StatementInvalid )
  end

  def survey_user
    @survey_user ||= begin
      attributes = { login: "survey_#{SecureRandom.hex( 6 )}", email: "#{SecureRandom.hex( 6 )}@example.org",
                     created_at: Time.current, updated_at: Time.current }
      User.find( User.insert_all!( [attributes] ).rows.first.first )
    end
  end

  def draft_version
    SurveyProtocol.create!( user: survey_user,
      title: "Bird point count" ).survey_protocol_versions.create!( version_number: 1 )
  end

  def target_for( version )
    version.survey_targets.create!( label: "Birds", scope_type: "taxon_group",
      scope_definition: { description: "All birds detected at the point" }, required: true )
  end

  def published_version
    version = draft_version
    target_for( version )
    PublishSurveyProtocolVersion.call( version )
  end
end

RSpec.configure do | config |
  config.define_derived_metadata( file_path: %r{/spec/surveys/} ) do | metadata |
    metadata[:survey] = true
  end
  config.include SurveySpecHelpers, survey: true
  config.around( :each, survey: true ) do | example |
    if example.metadata[:survey_concurrency]
      example.run
    else
      ActiveRecord::Base.transaction do
        example.run
        raise ActiveRecord::Rollback
      end
    end
  end
end
