-- Shared by the completion service and the database transition trigger. Taking
-- a proposed row permits validation of changed timing before UPDATE commits.
CREATE FUNCTION survey_completion_errors(e survey_events) RETURNS text[] LANGUAGE plpgsql STABLE AS $$
DECLARE problems text[] := ARRAY[]::text[]; config jsonb; field text;
BEGIN
  SELECT definition INTO config FROM survey_protocol_versions WHERE id = e.survey_protocol_version_id;
  IF e.started_at IS NULL THEN problems := array_append(problems, 'A start time is required'); END IF;
  IF EXISTS (SELECT FROM survey_targets t WHERE t.survey_protocol_version_id = e.survey_protocol_version_id
    AND NOT EXISTS (SELECT FROM survey_event_targets et WHERE et.survey_event_id = e.id AND et.survey_target_id = t.id)) THEN
    problems := array_append(problems, 'Every protocol target must be materialized');
  END IF;
  IF EXISTS (SELECT FROM survey_event_targets et JOIN survey_targets t ON t.id = et.survey_target_id
    WHERE et.survey_event_id = e.id AND t.required AND NOT (
      et.status = 'surveyed' OR
      (et.status = 'skipped' AND COALESCE((config->>'allow_skipped_targets')::boolean, false)) OR
      (et.status = 'not_applicable' AND COALESCE((config->>'allow_not_applicable_targets')::boolean, false)))) THEN
    problems := array_append(problems, 'Required targets must be assessed or explicitly permitted exceptions');
  END IF;
  IF COALESCE((config->>'require_effort')::boolean, true) AND
    NOT EXISTS (SELECT FROM survey_efforts WHERE survey_event_id = e.id) THEN
    problems := array_append(problems, 'Sampling effort is required');
  END IF;
  FOR field IN SELECT jsonb_array_elements_text(COALESCE(config->'required_effort_fields', '[]')) LOOP
    IF NOT EXISTS (SELECT FROM survey_efforts WHERE survey_event_id = e.id) OR EXISTS (
      SELECT FROM survey_efforts f WHERE f.survey_event_id = e.id AND (to_jsonb(f)->>field) IS NULL) THEN
      problems := array_append(problems, 'Effort requires ' || field);
    END IF;
  END LOOP;
  IF EXISTS (SELECT FROM survey_measurement_definitions d
    WHERE d.survey_protocol_version_id = e.survey_protocol_version_id AND d.required AND d.applies_to = 'event'
      AND NOT EXISTS (SELECT FROM survey_measurements m WHERE m.survey_event_id = e.id
        AND m.survey_measurement_definition_id = d.id AND m.survey_detection_id IS NULL)) THEN
    problems := array_append(problems, 'Required event measurements are missing');
  END IF;
  IF EXISTS (SELECT FROM survey_detections detection CROSS JOIN survey_measurement_definitions d
    WHERE detection.survey_event_id = e.id AND d.survey_protocol_version_id = e.survey_protocol_version_id
      AND d.required AND d.applies_to = 'detection' AND NOT EXISTS (
        SELECT FROM survey_measurements m WHERE m.survey_detection_id = detection.id
          AND m.survey_measurement_definition_id = d.id AND m.survey_event_id = e.id)) THEN
    problems := array_append(problems, 'Required detection measurements are missing');
  END IF;
  IF EXISTS (SELECT FROM survey_event_targets WHERE survey_event_id = e.id AND absence_reporting IS TRUE)
    AND NOT survey_has_positive_effort(e.id) THEN
    problems := array_append(problems, 'Absence reporting requires positive effort');
  END IF;
  RETURN problems;
END $$;

CREATE FUNCTION survey_enforce_event_completion() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE problems text[]; config jsonb;
BEGIN
  IF NEW.started_at IS DISTINCT FROM OLD.started_at OR NEW.ended_at IS DISTINCT FROM OLD.ended_at OR
     (NEW.status = 'completed' AND OLD.status <> 'completed') THEN
    SELECT definition INTO config FROM survey_protocol_versions WHERE id = NEW.survey_protocol_version_id;
    IF NOT COALESCE((config->>'allow_effort_outside_event')::boolean, false) AND EXISTS (
      SELECT FROM survey_efforts f WHERE f.survey_event_id = NEW.id AND
        (f.started_at < NEW.started_at OR f.ended_at > NEW.ended_at OR
         f.started_at > NEW.ended_at OR f.ended_at < NEW.started_at)) THEN
      RAISE EXCEPTION 'Event timing must contain existing effort';
    END IF;
  END IF;
  IF NEW.status = 'completed' AND OLD.status <> 'completed' THEN
    problems := survey_completion_errors(NEW);
    IF cardinality(problems) > 0 THEN RAISE EXCEPTION 'Cannot complete survey: %', array_to_string(problems, '; '); END IF;
    -- Serialize completion with edits to the reusable sampling geometry.
    IF NEW.survey_sampling_unit_id IS NOT NULL THEN
      UPDATE survey_sampling_units SET updated_at = clock_timestamp() WHERE id = NEW.survey_sampling_unit_id;
    END IF;
    NEW.completed_at := clock_timestamp();
  END IF;
  IF NEW.status = 'void' AND OLD.status <> 'void' THEN NEW.voided_at := clock_timestamp(); END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER survey_event_10_completion BEFORE UPDATE ON survey_events
  FOR EACH ROW EXECUTE FUNCTION survey_enforce_event_completion();

CREATE FUNCTION survey_freeze_used_unit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF ROW(NEW.geom,NEW.area_square_meters,NEW.length_meters,NEW.survey_site_id,
         NEW.parent_survey_sampling_unit_id,NEW.code,NEW.unit_type) IS DISTINCT FROM
     ROW(OLD.geom,OLD.area_square_meters,OLD.length_meters,OLD.survey_site_id,
         OLD.parent_survey_sampling_unit_id,OLD.code,OLD.unit_type) AND EXISTS (
       SELECT FROM survey_events WHERE survey_sampling_unit_id = OLD.id AND completed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'Used sampling geometry and identity are frozen; create a replacement unit';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER survey_used_unit_guard BEFORE UPDATE ON survey_sampling_units
  FOR EACH ROW EXECUTE FUNCTION survey_freeze_used_unit();

CREATE FUNCTION survey_guard_stable_uuid() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.uuid IS DISTINCT FROM OLD.uuid THEN RAISE EXCEPTION 'Survey UUID is stable'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER survey_protocol_uuid_guard BEFORE UPDATE ON survey_protocols
  FOR EACH ROW EXECUTE FUNCTION survey_guard_stable_uuid();
CREATE TRIGGER survey_site_uuid_guard BEFORE UPDATE ON survey_sites
  FOR EACH ROW EXECUTE FUNCTION survey_guard_stable_uuid();
