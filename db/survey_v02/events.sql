CREATE FUNCTION survey_guard_event_hierarchy() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' OR NEW.parent_survey_event_id IS DISTINCT FROM OLD.parent_survey_event_id THEN
    IF current_setting('transaction_isolation') <> 'read committed' THEN
      RAISE EXCEPTION 'Survey hierarchy edits require READ COMMITTED isolation';
    END IF;
    PERFORM pg_advisory_xact_lock(74321, 2);
    IF NEW.parent_survey_event_id = NEW.id OR EXISTS (
      WITH RECURSIVE ancestors AS (
        SELECT id, parent_survey_event_id FROM survey_events WHERE id = NEW.parent_survey_event_id
        UNION
        SELECT e.id, e.parent_survey_event_id FROM survey_events e
          JOIN ancestors a ON e.id = a.parent_survey_event_id
      ) SELECT FROM ancestors WHERE id = NEW.id
    ) THEN RAISE EXCEPTION 'Survey event cycle'; END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER survey_event_hierarchy_guard BEFORE INSERT OR UPDATE ON survey_events
  FOR EACH ROW EXECUTE FUNCTION survey_guard_event_hierarchy();

-- All child writes acquire and version their event row before checking joins.
-- The final integrity migration additionally freezes completed/void events.
CREATE FUNCTION survey_guard_event_child() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE event_id bigint;
BEGIN
  event_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.survey_event_id ELSE NEW.survey_event_id END;
  IF TG_OP = 'UPDATE' AND NEW.survey_event_id <> OLD.survey_event_id THEN
    RAISE EXCEPTION 'Scientific records cannot be moved between events';
  END IF;
  UPDATE survey_events SET updated_at = clock_timestamp()
    WHERE id = event_id AND status NOT IN ('completed','void');
  IF NOT FOUND THEN RAISE EXCEPTION 'Completed or void survey data is immutable'; END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER survey_event_target_00_lock BEFORE INSERT OR UPDATE OR DELETE ON survey_event_targets
  FOR EACH ROW EXECUTE FUNCTION survey_guard_event_child();
CREATE TRIGGER survey_participant_00_lock BEFORE INSERT OR UPDATE OR DELETE ON survey_event_participants
  FOR EACH ROW EXECUTE FUNCTION survey_guard_event_child();
CREATE TRIGGER survey_effort_00_lock BEFORE INSERT OR UPDATE OR DELETE ON survey_efforts
  FOR EACH ROW EXECUTE FUNCTION survey_guard_event_child();

CREATE FUNCTION survey_guard_event_target() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE t survey_targets; version_id bigint;
BEGIN
  SELECT survey_protocol_version_id INTO version_id FROM survey_events WHERE id = NEW.survey_event_id;
  SELECT * INTO t FROM survey_targets WHERE id = NEW.survey_target_id;
  IF t.survey_protocol_version_id IS DISTINCT FROM version_id THEN
    RAISE EXCEPTION 'Target must belong to the event protocol version';
  END IF;
  IF NEW.target_label_snapshot IS DISTINCT FROM t.label OR
     NEW.target_scope_snapshot IS DISTINCT FROM jsonb_build_object('scope_type',t.scope_type,'scope_definition',t.scope_definition) OR
     NEW.taxon_id_snapshot IS DISTINCT FROM t.taxon_id OR
     NEW.taxon_name_snapshot IS DISTINCT FROM t.taxon_name_snapshot OR
     NEW.external_taxon_uri_snapshot IS DISTINCT FROM t.external_taxon_uri THEN
    RAISE EXCEPTION 'Event target snapshots must match the published definition';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER survey_event_target_snapshot_guard BEFORE INSERT OR UPDATE ON survey_event_targets
  FOR EACH ROW EXECUTE FUNCTION survey_guard_event_target();

CREATE FUNCTION survey_guard_effort() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE e survey_events; config jsonb;
BEGIN
  SELECT * INTO e FROM survey_events WHERE id = NEW.survey_event_id;
  SELECT definition INTO config FROM survey_protocol_versions WHERE id = e.survey_protocol_version_id;
  IF config ? 'allowed_methods' AND NOT (config->'allowed_methods' ? NEW.method) THEN
    RAISE EXCEPTION 'Effort method is not allowed by the protocol';
  END IF;
  IF NOT COALESCE((config->>'allow_effort_outside_event')::boolean, false) AND
     (NEW.started_at < e.started_at OR NEW.ended_at > e.ended_at OR
      NEW.started_at > e.ended_at OR NEW.ended_at < e.started_at) THEN
    RAISE EXCEPTION 'Effort must fall within event timing';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER survey_effort_timing_guard BEFORE INSERT OR UPDATE ON survey_efforts
  FOR EACH ROW EXECUTE FUNCTION survey_guard_effort();

CREATE FUNCTION survey_guard_event() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE version_status text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status IN ('completed','void') OR OLD.completed_at IS NOT NULL THEN
      RAISE EXCEPTION 'Void historical surveys instead of deleting them';
    END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status NOT IN ('planned','in_progress') OR NEW.completed_at IS NOT NULL OR NEW.voided_at IS NOT NULL THEN
      RAISE EXCEPTION 'Create an event before completing or voiding it';
    END IF;
  ELSE
    IF NEW.uuid <> OLD.uuid OR NEW.survey_protocol_version_id <> OLD.survey_protocol_version_id THEN
      RAISE EXCEPTION 'Event identity and protocol version are permanent';
    END IF;
    IF OLD.status IN ('completed','void') THEN
      IF (to_jsonb(NEW) - ARRAY['trip_id','status','voided_at','void_reason','updated_at']) IS DISTINCT FROM
         (to_jsonb(OLD) - ARRAY['trip_id','status','voided_at','void_reason','updated_at']) OR
         (NEW.trip_id IS DISTINCT FROM OLD.trip_id AND NEW.trip_id IS NOT NULL) OR
         NOT (NEW.status = OLD.status OR (OLD.status = 'completed' AND NEW.status = 'void')) OR
         (OLD.status = 'void' AND ROW(NEW.voided_at,NEW.void_reason) IS DISTINCT FROM ROW(OLD.voided_at,OLD.void_reason)) THEN
        RAISE EXCEPTION 'Completed scientific records are immutable; void and replace to correct';
      END IF;
    END IF;
    IF NEW.completed_at IS DISTINCT FROM OLD.completed_at AND NOT
       (OLD.completed_at IS NULL AND NEW.status = 'completed') THEN
      RAISE EXCEPTION 'Completion provenance is immutable';
    END IF;
    IF NEW.status <> 'void' AND (NEW.voided_at IS NOT NULL OR NEW.void_reason IS NOT NULL) THEN
      RAISE EXCEPTION 'Voiding metadata requires void status';
    END IF;
    IF OLD.status = 'in_progress' AND NEW.status = 'planned' THEN
      RAISE EXCEPTION 'An active survey cannot return to planned';
    END IF;
  END IF;
  IF TG_OP = 'INSERT' OR (NEW.status IS DISTINCT FROM OLD.status AND NEW.status IN ('in_progress','completed')) THEN
    SELECT status INTO version_status FROM survey_protocol_versions
      WHERE id = NEW.survey_protocol_version_id FOR SHARE;
    IF version_status IS DISTINCT FROM 'published' THEN
      RAISE EXCEPTION 'Only published protocols may initialize, activate or complete events';
    END IF;
  END IF;
  IF NEW.trip_id IS NOT NULL THEN
    PERFORM 1 FROM posts WHERE id = NEW.trip_id AND type = 'Trip' FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Survey trip must reference a Trip'; END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER survey_event_guard BEFORE INSERT OR UPDATE OR DELETE ON survey_events
  FOR EACH ROW EXECUTE FUNCTION survey_guard_event();

-- Posts is STI. The FK alone cannot enforce its type, including reverse edits.
CREATE FUNCTION survey_guard_trip_type() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.type IS DISTINCT FROM 'Trip' AND EXISTS (SELECT FROM survey_events WHERE trip_id = OLD.id) THEN
    RAISE EXCEPTION 'A Post referenced by survey events must remain a Trip';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER survey_trip_type_guard BEFORE UPDATE OF type ON posts
  FOR EACH ROW EXECUTE FUNCTION survey_guard_trip_type();
