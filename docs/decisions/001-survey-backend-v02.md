# Survey backend v0.2

Status: accepted for implementation by Steve's v0.2 task; initial policy choices
are provisional pending real protocol review. Date: 2026-10-15.

## Assessment and alternatives

Rails 6.1.7.9 / Ruby 3.3.7 uses the PostGIS adapter and SQL structure dumps.
The local test server is PostgreSQL 17.11 / PostGIS 3.6.4 (matching the
repository's PostgreSQL 17 / PostGIS 3.6 development images). All five referenced
legacy tables have integer primary keys; new tables use Rails bigint keys.
RSpec, FactoryBot and Machinist are available. Services normally live in `lib/`.
No existing Survey model or table conflicts were found.

Trip inherits Post through STI. Post has an observations_posts join, but Trip
redefines observations as user/time/place discovery, and its presence_absence
method uses Elasticsearch. TripPurpose and TripTaxon do not represent versioned
protocols, effort, stable sampling units, or explicit non-detections. Existing
ObservationFields/ControlledTerms attach values to observations, not protocol
versions or independent survey events. Places describe geographic regions,
not sampling identities. These existing behaviors remain intact.

Alternatives were extending TripPurpose alone, adding protocol fields directly
to Posts, or composing Trips with the 13-table structure specified by Steve.
Choose the approved composition: optional Trip association, separate explicit
Observation links, existing taxa and users, no old-table column changes.
This adds no HTTP or search behavior, dependencies, or taxonomy machinery.

## Integrity decisions

Use foreign keys/checks/unique indexes first, and narrowly scoped PostgreSQL
triggers for publication, completion, snapshots, cross-version relationships,
ancestry and historical freezing. Parent rows serialize scientific writes and
publication/completion. Use fixed advisory locks for hierarchy edits and enforce
READ COMMITTED for these edits; ordinary Rails transactions use that isolation.
Service objects are small Ruby classes in lib, not a new workflow framework.

Configuration supports only documented sampling/completion keys and numeric
min/max rules. Reject unknown keys instead of silently ignoring scientific rules.
Completed records are frozen; correction means voiding with a reason and creating
a new event, retaining the original. Sampling unit spatial identity freezes on
completed use, including when that event is later voided. Event geometry is an
explicit snapshot, initialized from the unit if not supplied, never from a later
site edit. UUID ingestion keys on detections deduplicate retries without making
event/taxon unique. This is a small addition to the requested column list.

Observation links alone cascade when an underlying Observation is deleted,
consistent with existing deletion behavior. Trip deletion nullifies event links.
Users, taxa and places referenced by scientific records use restrictive FKs;
account erasure/anonymization policy needs future design. No silent retargeting.
Geometry is excluded from all default survey serialization and inspect output;
authorized export and location disclosure policy remain future work.

## Migration and test strategy

Add phased, versioned migrations, followed by dedicated integrity SQL. Never
rewrite old migrations or reset/reseed the populated databases. Apply and test
against an explicitly selected test database, including raw SQL bypasses and
multi-connection races. Use SQL structure dumps because Ruby schema dumps cannot
preserve triggers. Keep development data untouched during implementation.
