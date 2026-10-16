# frozen_string_literal: true

require_relative "survey_spec_helper"

RSpec.describe "Survey protocols" do
  it "persists editable drafts and publishes all four measurement types" do
    version = draft_version
    target_for( version )
    version.update!( instructions: "Count for ten minutes" )
    %w(numeric text boolean categorical).each do | kind |
      version.survey_measurement_definitions.create!( field_key: kind, label: kind, data_type: kind,
        allowed_values: ( kind == "categorical" ) ? %w(clear cloudy) : [] )
    end
    expect( PublishSurveyProtocolVersion.call( version ).reload.status ).to eq "published"
    expect( version.published_at ).to be_present
    expect( version.survey_protocol.uuid ).to be_present
  end

  it "rejects incomplete publication and rolls back" do
    version = draft_version
    expect { PublishSurveyProtocolVersion.call( version ) }.to raise_error( ActiveRecord::RecordInvalid )
    expect( version.reload.status ).to eq "draft"
    rejects_sql "UPDATE survey_protocol_versions SET status='published', published_at=now() WHERE id=#{version.id}"
  end

  it "protects scientific definitions against direct SQL and allows retirement only" do
    version = published_version
    rejects_sql "UPDATE survey_protocol_versions SET instructions='changed' WHERE id=#{version.id}"
    rejects_sql "DELETE FROM survey_protocol_versions WHERE id=#{version.id}"
    rejects_sql "UPDATE survey_targets SET label='changed' WHERE survey_protocol_version_id=#{version.id}"
    rejects_sql "DELETE FROM survey_targets WHERE survey_protocol_version_id=#{version.id}"
    version.update!( status: "retired" )
    rejects_sql "UPDATE survey_protocol_versions SET status='draft', published_at=NULL WHERE id=#{version.id}"
    expect( version.survey_targets.count ).to eq 1
  end

  it "rejects undocumented configuration and invalid numeric rules" do
    version = draft_version
    expect( version.update( definition: { code: "eval" } ) ).to be false
    rejects_sql "UPDATE survey_protocol_versions SET definition='{\"allowed_methods\": [4]}' WHERE id=#{version.id}"
    field = version.survey_measurement_definitions.build( field_key: "temperature", label: "Temperature",
      data_type: "numeric", validation_rules: { min: 40, max: 1 } )
    expect( field ).not_to be_valid
  end

  it "preserves inactive taxon names and supports verbatim targets" do
    taxon = Taxon.find( Taxon.insert_all!( [{ name: "Historical birds", is_active: false,
                                              created_at: Time.current, updated_at: Time.current }] ).rows.first.first )
    version = draft_version
    target = version.survey_targets.create!( label: "Birds", scope_type: "taxon", taxon: taxon )
    version.survey_targets.create!( label: "Nests", scope_type: "verbatim",
      scope_definition: { description: "Occupied nests" } )
    PublishSurveyProtocolVersion.call( version )
    taxon.update_columns( name: "Renamed birds" )
    expect( target.reload.taxon_name_snapshot ).to eq "Historical birds"
    expect( target.taxon.is_active ).to be false
  end
end
