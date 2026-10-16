-- Locks apply only to hierarchy changes, never spatial reads. The fixed lock
-- prevents two simultaneous inverse edges from both passing the ancestry query.
CREATE FUNCTION survey_guard_unit_hierarchy() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.uuid IS DISTINCT FROM OLD.uuid THEN
    RAISE EXCEPTION 'Sampling unit UUID is stable';
  END IF;
  IF TG_OP = 'INSERT' OR NEW.parent_survey_sampling_unit_id IS DISTINCT FROM OLD.parent_survey_sampling_unit_id
    OR NEW.survey_site_id IS DISTINCT FROM OLD.survey_site_id THEN
    IF current_setting('transaction_isolation') <> 'read committed' THEN
      RAISE EXCEPTION 'Survey hierarchy edits require READ COMMITTED isolation';
    END IF;
    PERFORM pg_advisory_xact_lock(74321, 1);
    IF NEW.parent_survey_sampling_unit_id = NEW.id OR EXISTS (
      WITH RECURSIVE ancestors AS (
        SELECT id, parent_survey_sampling_unit_id FROM survey_sampling_units WHERE id = NEW.parent_survey_sampling_unit_id
        UNION
        SELECT u.id, u.parent_survey_sampling_unit_id FROM survey_sampling_units u
          JOIN ancestors a ON u.id = a.parent_survey_sampling_unit_id
      ) SELECT FROM ancestors WHERE id = NEW.id
    ) THEN RAISE EXCEPTION 'Survey sampling unit cycle'; END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER survey_unit_hierarchy_guard BEFORE INSERT OR UPDATE ON survey_sampling_units
  FOR EACH ROW EXECUTE FUNCTION survey_guard_unit_hierarchy();
