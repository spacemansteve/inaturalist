# frozen_string_literal: true

require_relative "survey_spec_helper"

RSpec.describe "Survey spatial sampling" do
  let( :site ) { SurveySite.create!( name: "Monitoring site", created_by_user: survey_user, geom: "POINT(-71 42)" ) }
  def unit( code, attributes = {} )
    site.survey_sampling_units.create!( { code: code, unit_type: "point", geom: "POINT(-71 42)" }.merge( attributes ) )
  end

  it "persists multiple identifiable spatial units" do
    parent = unit( "A" )
    child = unit( "B", parent_survey_sampling_unit: parent )
    expect( child.reload.geom.srid ).to eq 4326
    expect( site.survey_sampling_units.count ).to eq 2
    expect( site.reload.location_privacy ).to eq "private"
    expect( parent.uuid ).not_to eq child.uuid
  end

  it "rejects cycles and parents at another site even without Rails validations" do
    a = unit( "A" )
    b = unit( "B", parent_survey_sampling_unit: a )
    rejects_sql "UPDATE survey_sampling_units SET parent_survey_sampling_unit_id=#{b.id} WHERE id=#{a.id}"
    rejects_sql "UPDATE survey_sampling_units SET parent_survey_sampling_unit_id=id WHERE id=#{a.id}"
    other = SurveySite.create!( name: "Other", created_by_user: survey_user )
    rejects_sql "UPDATE survey_sampling_units SET survey_site_id=#{other.id} WHERE id=#{b.id}"
  end

  it "rejects invalid geometry, SRIDs and negative dimensions" do
    a = unit( "A" )
    rejects_sql "UPDATE survey_sampling_units SET length_meters=-1 WHERE id=#{a.id}"
    rejects_sql "UPDATE survey_sites SET geom=ST_GeomFromText('POINT(1 1)',3857) WHERE id=#{site.id}"
    rejects_sql "UPDATE survey_sites SET geom=ST_GeomFromText('POLYGON((0 0,1 1,1 0,0 1,0 0))',4326) " \
      "WHERE id=#{site.id}"
    rejects_sql "UPDATE survey_sites SET geom=ST_GeomFromText('POINT(190 42)',4326) WHERE id=#{site.id}"
  end

  it "redacts geometry binds in routine Rails SQL logs" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new( output )
    logger.level = Logger::DEBUG
    old_logger = ActiveRecord::Base.logger
    begin
      ActiveRecord::Base.logger = logger
      record = SurveySite.create!( name: "Private", created_by_user: survey_user, geom: "POINT(-71.123456 42.654321)" )
      record.update!( geom: "POINT(-71.234567 42.765432)" )
      expect( record.reload.geom.x ).to eq( -71.234567 )
    ensure
      ActiveRecord::Base.logger = old_logger
    end
    expect( output.string ).to include "bytes of binary data"
    expect( output.string ).not_to include "71.123456", "42.654321", "71.234567", "42.765432", "0101000020"
  end

  it "excludes geometry from serialization and inspect even when explicitly requested" do
    expect( site.as_json ).not_to have_key "geom"
    expect( site.as_json( only: :geom, methods: :geom ) ).to eq( {} )
    expect( site.inspect ).not_to include "POINT"
    expect( unit( "A" ).as_json( include: :survey_site ) ).not_to have_key "survey_site"
  end
end
