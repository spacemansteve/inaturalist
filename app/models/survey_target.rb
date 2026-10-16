# frozen_string_literal: true

class SurveyTarget < SurveyRecord
  belongs_to :survey_protocol_version
  belongs_to :taxon, optional: true
  has_many :survey_event_targets, dependent: :restrict_with_error
  before_validation :snapshot_taxon_name, on: :create
  validates :survey_protocol_version, :label, presence: true
  validates :scope_type, inclusion: { in: %w(taxon taxon_group verbatim) }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validate :valid_scope
  validate :draft_version

  private

  def snapshot_taxon_name
    self.taxon_name_snapshot ||= taxon&.name
  end

  def valid_scope
    valid = scope_definition.is_a?( Hash )
    valid &&= if scope_type == "taxon"
      taxon.present? && taxon_name_snapshot.present? && scope_definition.empty?
    else
      scope_definition.keys == ["description"] && scope_definition["description"].is_a?( String ) &&
        scope_definition["description"].present? && ( scope_type != "verbatim" || taxon_id.nil? )
    end
    errors.add( :scope_definition, "does not match scope type" ) unless valid
  end

  def draft_version
    errors.add( :survey_protocol_version, "must be a draft" ) if survey_protocol_version &&
      survey_protocol_version.status != "draft"
  end
end
