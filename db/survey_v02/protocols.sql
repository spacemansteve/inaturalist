-- Versioned migration asset. Do not edit after deployment; add a new migration.
CREATE FUNCTION survey_valid_protocol_definition(d jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE k text; v jsonb;
BEGIN
  IF jsonb_typeof(d) <> 'object' THEN RETURN false; END IF;
  FOR k, v IN SELECT * FROM jsonb_each(d) LOOP
    IF k IN ('require_effort','allow_skipped_targets','allow_not_applicable_targets','allow_effort_outside_event') THEN
      IF jsonb_typeof(v) <> 'boolean' THEN RETURN false; END IF;
    ELSIF k IN ('allowed_methods','required_effort_fields') THEN
      IF jsonb_typeof(v) <> 'array' OR jsonb_array_length(v) = 0 THEN RETURN false; END IF;
      IF EXISTS (SELECT FROM jsonb_array_elements(v) x WHERE jsonb_typeof(x) <> 'string' OR btrim(x #>> '{}') = '') THEN
        RETURN false;
      END IF;
      IF k = 'required_effort_fields' AND EXISTS (
        SELECT FROM jsonb_array_elements_text(v) x WHERE x NOT IN
          ('duration_seconds','distance_meters','area_square_meters','observer_count','replicate_number')) THEN RETURN false;
      END IF;
    ELSE RETURN false;
    END IF;
  END LOOP;
  RETURN true;
END $$;
ALTER TABLE survey_protocol_versions ADD CONSTRAINT survey_protocol_configuration
  CHECK (survey_valid_protocol_definition(definition));

CREATE FUNCTION survey_valid_measurement_definition(kind text, vals jsonb, rules jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF jsonb_typeof(vals) <> 'array' OR jsonb_typeof(rules) <> 'object' THEN RETURN false; END IF;
  IF kind = 'categorical' THEN
    IF jsonb_array_length(vals) = 0 OR EXISTS (
      SELECT FROM jsonb_array_elements(vals) x WHERE jsonb_typeof(x) <> 'string' OR btrim(x #>> '{}') = '')
      OR (SELECT count(*) <> count(DISTINCT x) FROM jsonb_array_elements(vals) x) THEN RETURN false;
    END IF;
  ELSIF vals <> '[]'::jsonb THEN RETURN false;
  END IF;
  IF kind <> 'numeric' THEN RETURN rules = '{}'::jsonb; END IF;
  IF rules - ARRAY['min','max'] <> '{}'::jsonb THEN RETURN false; END IF;
  IF (rules ? 'min' AND jsonb_typeof(rules->'min') <> 'number') OR
     (rules ? 'max' AND jsonb_typeof(rules->'max') <> 'number') THEN RETURN false; END IF;
  RETURN NOT (rules ?& ARRAY['min','max']) OR (rules->>'min')::numeric <= (rules->>'max')::numeric;
END $$;
ALTER TABLE survey_measurement_definitions ADD CONSTRAINT survey_measurement_configuration
  CHECK (survey_valid_measurement_definition(data_type, allowed_values, validation_rules));

CREATE FUNCTION survey_guard_protocol_version() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.published_at IS NOT NULL THEN RAISE EXCEPTION 'Published survey versions cannot be deleted'; END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' THEN RAISE EXCEPTION 'Create a draft before publication'; END IF;
  ELSE
    IF OLD.published_at IS NOT NULL THEN
      IF (to_jsonb(NEW) - ARRAY['status','updated_at']) IS DISTINCT FROM
         (to_jsonb(OLD) - ARRAY['status','updated_at']) OR
         NOT (NEW.status = OLD.status OR (OLD.status = 'published' AND NEW.status = 'retired')) THEN
        RAISE EXCEPTION 'Published survey definitions are immutable';
      END IF;
    ELSIF NEW.status <> OLD.status THEN
      IF NEW.status <> 'published' OR NOT EXISTS (
        SELECT FROM survey_targets WHERE survey_protocol_version_id = NEW.id) THEN
        RAISE EXCEPTION 'Publication requires a draft with at least one target';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER survey_protocol_version_guard BEFORE INSERT OR UPDATE OR DELETE ON survey_protocol_versions
  FOR EACH ROW EXECUTE FUNCTION survey_guard_protocol_version();

-- Updating the parent serializes child edits with publication, also forcing a
-- serialization failure rather than a stale snapshot under REPEATABLE READ.
CREATE FUNCTION survey_guard_protocol_child() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE parent_id bigint;
BEGIN
  parent_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.survey_protocol_version_id ELSE NEW.survey_protocol_version_id END;
  IF TG_OP = 'UPDATE' AND NEW.survey_protocol_version_id <> OLD.survey_protocol_version_id THEN
    RAISE EXCEPTION 'Move definitions by copying them into a new version';
  END IF;
  UPDATE survey_protocol_versions SET updated_at = clock_timestamp()
    WHERE id = parent_id AND status = 'draft';
  IF NOT FOUND THEN RAISE EXCEPTION 'Only draft survey definitions can be edited'; END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER survey_target_guard BEFORE INSERT OR UPDATE OR DELETE ON survey_targets
  FOR EACH ROW EXECUTE FUNCTION survey_guard_protocol_child();
CREATE TRIGGER survey_measurement_definition_guard BEFORE INSERT OR UPDATE OR DELETE ON survey_measurement_definitions
  FOR EACH ROW EXECUTE FUNCTION survey_guard_protocol_child();
