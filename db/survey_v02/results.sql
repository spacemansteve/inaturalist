CREATE TRIGGER survey_detection_00_lock BEFORE INSERT OR UPDATE OR DELETE ON survey_detections
  FOR EACH ROW EXECUTE FUNCTION survey_guard_event_child();
CREATE TRIGGER survey_measurement_00_lock BEFORE INSERT OR UPDATE OR DELETE ON survey_measurements
  FOR EACH ROW EXECUTE FUNCTION survey_guard_event_child();

-- A non-detection is an explicit report about one assessed target. Positive
-- effort is a conservative minimum, not a universal assertion of detectability.
CREATE FUNCTION survey_has_positive_effort(event_id bigint) RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT FROM survey_efforts WHERE survey_event_id = event_id AND
    (duration_seconds > 0 OR distance_meters > 0 OR area_square_meters > 0));
$$;
CREATE FUNCTION survey_guard_detection() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.uuid <> OLD.uuid THEN RAISE EXCEPTION 'Detection ingestion UUID is stable'; END IF;
  IF NEW.occurrence_status = 'absent' THEN
    IF NOT EXISTS (SELECT FROM survey_event_targets WHERE id = NEW.survey_event_target_id
      AND survey_event_id = NEW.survey_event_id AND status = 'surveyed'
      AND coverage_complete IS TRUE AND absence_reporting IS TRUE) OR
      NOT survey_has_positive_effort(NEW.survey_event_id) THEN
      RAISE EXCEPTION 'Non-detection requires an assessed target, complete coverage and positive effort';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER survey_detection_semantics_guard BEFORE INSERT OR UPDATE ON survey_detections
  FOR EACH ROW EXECUTE FUNCTION survey_guard_detection();

CREATE FUNCTION survey_guard_measurement() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE d survey_measurement_definitions; version_id bigint;
BEGIN
  SELECT * INTO d FROM survey_measurement_definitions WHERE id = NEW.survey_measurement_definition_id;
  SELECT survey_protocol_version_id INTO version_id FROM survey_events WHERE id = NEW.survey_event_id;
  IF d.survey_protocol_version_id IS DISTINCT FROM version_id THEN
    RAISE EXCEPTION 'Measurement definition must belong to the event protocol';
  END IF;
  IF (d.applies_to = 'event' AND NEW.survey_detection_id IS NOT NULL) OR
     (d.applies_to = 'detection' AND NEW.survey_detection_id IS NULL) THEN
    RAISE EXCEPTION 'Measurement scope does not match the definition';
  END IF;
  IF NEW.unit IS DISTINCT FROM d.unit THEN RAISE EXCEPTION 'Measurement unit does not match the definition'; END IF;
  IF (d.data_type = 'numeric' AND NEW.value_numeric IS NULL) OR
     (d.data_type IN ('text','categorical') AND NEW.value_text IS NULL) OR
     (d.data_type = 'boolean' AND NEW.value_boolean IS NULL) THEN
    RAISE EXCEPTION 'Measurement value does not match declared type';
  END IF;
  IF d.data_type = 'categorical' AND NOT (d.allowed_values ? NEW.value_text) THEN
    RAISE EXCEPTION 'Measurement category is outside its vocabulary';
  END IF;
  IF d.data_type = 'numeric' AND (NEW.value_numeric < (d.validation_rules->>'min')::numeric OR
     NEW.value_numeric > (d.validation_rules->>'max')::numeric) THEN
    RAISE EXCEPTION 'Measurement is outside its declared range';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER survey_measurement_semantics_guard BEFORE INSERT OR UPDATE ON survey_measurements
  FOR EACH ROW EXECUTE FUNCTION survey_guard_measurement();

-- Unlinking is intentionally allowed after completion and during an Observation
-- FK cascade. It deletes evidence links only, never detections or measurements.
CREATE FUNCTION survey_guard_observation_link() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  IF TG_OP = 'UPDATE' THEN RAISE EXCEPTION 'Unlink and recreate observation links instead of rewriting them'; END IF;
  UPDATE survey_events SET updated_at = clock_timestamp()
    WHERE id = NEW.survey_event_id AND status NOT IN ('completed','void');
  IF NOT FOUND THEN RAISE EXCEPTION 'Cannot attach evidence to a completed or void survey'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER survey_observation_link_guard BEFORE INSERT OR UPDATE OR DELETE ON survey_observations
  FOR EACH ROW EXECUTE FUNCTION survey_guard_observation_link();

-- Reverse checks are essential: a valid absence cannot be invalidated by later
-- changing its assessment or deleting / zeroing the only positive effort.
CREATE FUNCTION survey_check_absence_context() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE event_id bigint;
BEGIN
  event_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.survey_event_id ELSE NEW.survey_event_id END;
  IF EXISTS (SELECT FROM survey_event_targets WHERE survey_event_id = event_id AND absence_reporting IS TRUE)
    AND NOT survey_has_positive_effort(event_id) THEN
    RAISE EXCEPTION 'Absence reporting requires positive sampling effort';
  END IF;
  IF EXISTS (SELECT FROM survey_detections d JOIN survey_event_targets t ON t.id = d.survey_event_target_id
    WHERE d.survey_event_id = event_id AND d.occurrence_status = 'absent'
      AND (t.status <> 'surveyed' OR t.coverage_complete IS NOT TRUE OR t.absence_reporting IS NOT TRUE)) THEN
    RAISE EXCEPTION 'Existing non-detections require complete absence-enabled targets';
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER survey_target_absence_context AFTER INSERT OR UPDATE OR DELETE ON survey_event_targets
  FOR EACH ROW EXECUTE FUNCTION survey_check_absence_context();
CREATE TRIGGER survey_effort_absence_context AFTER INSERT OR UPDATE OR DELETE ON survey_efforts
  FOR EACH ROW EXECUTE FUNCTION survey_check_absence_context();
