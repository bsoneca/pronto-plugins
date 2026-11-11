// pronto-migrations' rules (../../migrations/plan.js) on the inputs they were written for: the model
// read from an emitted proto and pronto's facts, the changes between two models, the SQL each needs,
// and the files make writes. `mig` edits a model and runs the rules on the edit (migrations.js).
package unit

import "strings"

// An entity as the model holds it: a pk, a machine's column with a default, an optional column, a
// required unique reference, an enum and a checked number; a unique index and a plain one.
_order: Order: {
	table: "order"
	id:    "0x01"
	fields: {
		"1": {name: "id", type: "uuid", proto: "string", required: true, pk: true}
		"2": {name: "status", type: "string", sql: "text", proto: "string", required: true, default: "'draft'", enum: ["draft", "open", "closed"], machine: true}
		"3": {name: "note", type: "string", proto: "string", required: false}
		"4": {name: "ref", type: "uuid", proto: "string", required: true, unique: true, ref: "customer"}
		"5": {name: "stage", type: "string", proto: "string", required: true, default: "'new'", enum: ["new", "paid"]}
		"6": {name: "total", type: "int64", proto: "int64", required: false, check: "total >= 0"}
	}
	retired: {}
	indexes: {
		order_ref_status: {cols: ["ref", "status"], unique: true}
		idx_order_note: {cols: ["note"], using: "btree"}
	}
}

// The same with number 7 retired.
_retired: Order: _order.Order & {retired: "7": {name: "legacy", type: "string", required: false}}

_carryValues: {carry: Order: stage: values: paid: "settled"}
_stageNarrowed: [["Order.fields.5.enum", ["new", "settled"]]]

// A move's block (a carry, a backfill, a copy) on order: it runs only where a row matches, and every
// check on the table but those kept is lifted around the update and put back as the database held
// it, NOT VALID. Of `triggers`, those on are turned off around it and put back in their mode.
_move: {
	tag:    "$carry$" | "$fill$"
	where:  string
	update: string
	kept:   *"" | string
	triggers: *[] | [...string]
	_each:    "FOR pronto_i IN 1 .. coalesce(array_length(pronto_lifted, 1), 0) LOOP"
	_eachOff: "FOR pronto_t IN 1 .. coalesce(array_length(pronto_off, 1), 0) LOOP"
	_names: strings.Join([for x in triggers {"'\(x)'"}], ", ")
	text: strings.Join([
		"DO \(tag)",
		"DECLARE",
		"  pronto_lifted text[];",
		"  pronto_defs text[];",
		if len(triggers) > 0 {"  pronto_off text[];"},
		if len(triggers) > 0 {"  pronto_modes text[];"},
		"BEGIN",
		"  IF EXISTS (SELECT FROM \"public\".\"order\" WHERE \(where)) THEN",
		if len(triggers) > 0 {"    LOCK TABLE \"public\".\"order\" IN ACCESS EXCLUSIVE MODE;"},
		if len(triggers) > 0 {"    SELECT array_agg(tgname::text ORDER BY tgname), array_agg(tgenabled::text ORDER BY tgname) INTO pronto_off, pronto_modes FROM pg_trigger WHERE tgrelid = '\"public\".\"order\"'::regclass AND tgname = ANY (ARRAY[\(_names)]) AND tgenabled <> 'D';"},
		if len(triggers) > 0 {"    \(_eachOff) EXECUTE 'ALTER TABLE \"public\".\"order\" DISABLE TRIGGER ' || quote_ident(pronto_off[pronto_t]); END LOOP;"},
		"    SELECT array_agg(conname ORDER BY conname), array_agg(pg_get_constraintdef(oid) ORDER BY conname) INTO pronto_lifted, pronto_defs FROM pg_constraint WHERE conrelid = '\"public\".\"order\"'::regclass AND contype = 'c'\(kept);",
		"    \(_each) EXECUTE 'ALTER TABLE \"public\".\"order\" DROP CONSTRAINT ' || quote_ident(pronto_lifted[pronto_i]); END LOOP;",
		"    \(update)",
		"    \(_each) EXECUTE 'ALTER TABLE \"public\".\"order\" ADD CONSTRAINT ' || quote_ident(pronto_lifted[pronto_i]) || ' ' || pronto_defs[pronto_i] || CASE WHEN pronto_defs[pronto_i] LIKE '%NOT VALID' THEN '' ELSE ' NOT VALID' END; END LOOP;",
		if len(triggers) > 0 {"    \(_eachOff) EXECUTE 'ALTER TABLE \"public\".\"order\" ENABLE ' || CASE pronto_modes[pronto_t] WHEN 'A' THEN 'ALWAYS ' WHEN 'R' THEN 'REPLICA ' ELSE '' END || 'TRIGGER ' || quote_ident(pronto_off[pronto_t]); END LOOP;"},
		"  END IF;",
		"END \(tag);",
	], "\n")
}

// A backfill of note: every check but note's own lifted.
_fillNote: {
	value: string
	text: (_move & {tag: "$fill$", where: #""note" IS NULL"#, update: #"UPDATE "public"."order" SET "note" = "# + value + #" WHERE "note" IS NULL;"#, kept: " AND conname <> ALL (ARRAY['order_note_check', 'order_note_type'])"}).text
}

_proto: """
	syntax = "proto3";
	package pronto.entities;

	import "google/protobuf/timestamp.proto";

	message Order {
	  optional string id = 1 [json_name = "id"];
	  reserved 2;
	  reserved "legacy";
	  google.protobuf.Timestamp at = 3 [json_name = "at"];
	  repeated string tags = 4;
	  reserved 5 to 7, 9;
	}

	"""

_facts: {
	version: 1
	types: {
		aliases: {text: "string", int: "int32", timestamptz: "timestamp"}
		types: {string: {column: "plain", pg: "text"}, uuid: {column: "plain", pg: "uuid"}, timestamp: {column: "domain", sql: "portable_timestamp", pg: "timestamptz"}}
	}
	entities: {
		Order: {
			server: true
			table:  "order"
			id:     "0x01"
			fields: [
				{name: "id", ordinal: 1, retired: false, type: "uuid", pk: true, required: true},
				{name: "status", ordinal: 2, retired: false, type: "text", pk: false, required: true},
				{name: "old", ordinal: 3, retired: true, type: "string", pk: false, required: false, default: "''"},
				{name: "total", ordinal: 4, retired: false, type: "decimal", precision: 10, scale: 2, pk: false, required: false, cel: "this >= 0"},
				{name: "owner", ordinal: 5, retired: false, type: "uuid", pk: false, required: true, ref: "app_user", default: "auth_uid()"},
			]
			cel: {enums: {}, checks: {total: "total >= 0"}}
			uniques: [{name: "Order_Status", cols: ["status"]}]
			indexes: [{on: "status", using: "btree"}]
		}
		// An entity with no table (a device's) is not the database's.
		Draft: {server: false, table: "draft", id: "0x02", fields: [{name: "id", ordinal: 1, retired: false, type: "uuid", pk: true, required: true}], cel: {enums: {}, checks: {}}, uniques: []}
	}
}

_modelProto: """
	message Order {
	  optional string id = 1;
	  optional string status = 2;
	  reserved 3;
	  reserved "old";
	  optional string total = 4;
	  optional string owner = 5;
	}

	"""

_machines: #"""
	ALTER TABLE "order" DROP CONSTRAINT IF EXISTS "order_status_check";
	ALTER TABLE "order" ADD CONSTRAINT "order_status_check" CHECK ("status" IN ('draft', 'open', 'it''s')) NOT VALID;
	CREATE TRIGGER "trg_order_status_machine"
	"""#

// What 005_create_tables.sql writes for order: each column in its CREATE TABLE, and again (but the
// primary key) as an ADD COLUMN, from the same clause, then its indexes. status, a machine's column,
// has the default pronto writes from its initial state, which the facts do not state.
_tables: #"""
	CREATE TABLE IF NOT EXISTS "order" (
	  "id" uuid PRIMARY KEY,
	  "status" text DEFAULT 'draft' NOT NULL CHECK ("status" IN ('draft', 'open', 'it''s')),
	  "old" TEXT DEFAULT '',
	  "total" portable_decimal_10_2 CHECK (total >= 0),
	  "owner" uuid DEFAULT auth_uid() NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
	  "txid" BIGINT DEFAULT pg_current_xact_id()::text::bigint
	);
	ALTER TABLE order ADD COLUMN IF NOT EXISTS "status" text DEFAULT 'draft' NOT NULL CHECK ("status" IN ('draft', 'open', 'it''s'));
	ALTER TABLE order ADD COLUMN IF NOT EXISTS "old" TEXT DEFAULT '';
	ALTER TABLE order ADD COLUMN IF NOT EXISTS "total" portable_decimal_10_2 CHECK (total >= 0);
	ALTER TABLE order ADD COLUMN IF NOT EXISTS "owner" uuid DEFAULT auth_uid() NOT NULL REFERENCES app_user(id) ON DELETE CASCADE;
	CREATE INDEX IF NOT EXISTS idx_order_status ON order USING btree (status);
	CREATE UNIQUE INDEX IF NOT EXISTS Order_Status ON order (status);
	"""#

_sql: {machines: _machines, tables: _tables}

_t:   #""public"."order""#

cases: {
	"the proto: each field's number, name and type, what each message reserves, and nothing pronto does not emit": {suite: "migrations", steps: [
		{call: "migrations.parseProto", args: [_proto], holds: {Order: {
			fields: {"1": {name: "id", type: "string"}, "3": {name: "at", type: "google.protobuf.Timestamp"}, "4": {name: "tags", type: "repeated string"}}
			reserved: {numbers: [2, 5, 6, 7, 9], names: ["legacy"]}
		}}},
		{call: "migrations.parseProto", args: ["message A {\n  enum K { X = 0; }\n}\n"], throws: "entities.proto:2: not what pronto emits", why: "an enum is not read as a field"},
		{call: "migrations.parseProto", args: ["message A {\n  optional string id = 1;\n"], throws: "not closed"},
		{call: "migrations.parseProto", args: ["message A {\n  optional string id = 1;\n  optional string other = 1;\n}\n"], throws: "number 1 twice"},
	]}
	"the model: the proto names a column, pronto's facts say what it holds, a retired one included, and the machines their states": {suite: "migrations", steps: [
		{call: "migrations.model", args: [_modelProto, _facts, _sql], holds: {Order: {
			table: "order"
			id:    "0x01"
			fields: {
				"1": {name: "id", type: "uuid", sql: "uuid", proto: "string", required: true, pk: true}
				"2": {name: "status", type: "string", sql: "text", proto: "string", required: true, default: "'draft'", enum: ["draft", "open", "it's"], machine: true}
				"4": {name: "total", type: "decimal(10,2)", sql: "portable_decimal_10_2", proto: "string", required: false, check: "total >= 0"}
				"5": {name: "owner", type: "uuid", sql: "uuid", proto: "string", required: true, ref: "app_user", default: "auth_uid()"}
			}
			retired: {"3": {name: "old", type: "string", sql: "text", required: false, default: "''"}}
			indexes: {order_status: {cols: ["status"], unique: true}, idx_order_status: {cols: ["status"], using: "btree"}}
		}}, why: "an alias is its type (text is string), a column keeps the type and the default 005 writes (status's, a machine's initial state, which the facts do not state), a decimal carries its precision and scale, and an index's name is as Postgres keeps an unquoted one"
		},
		{get: "Draft", matches: "^undefined$", why: "an entity with no table is not the database's"},
	]}
	"a proto, facts and an emitted schema that disagree, or a pronto this does not read, are refused, never guessed": {suite: "migrations", steps: [
		{call: "migrations.model", args: ["message Order {\n  optional string id = 1;\n  optional string state = 2;\n  reserved 3;\n  reserved \"old\";\n  optional string total = 4;\n  optional string owner = 5;\n}\n", _facts, _sql], throws: "^Order.status: entities.proto has state at 2: run generate$"},
		{call: "migrations.model", args: ["message Order {\n  optional string id = 1;\n  optional string status = 2;\n  optional string total = 4;\n  optional string owner = 5;\n}\n", _facts, _sql], throws: "Order.old: retired, and entities.proto does not reserve 3"},
		{call: "migrations.model", args: ["message Order {\n  optional string id = 1;\n  optional string status = 2;\n  reserved 3;\n  reserved \"old\";\n  optional string total = 4;\n  optional string owner = 5;\n  optional string extra = 6;\n}\n", _facts, _sql], throws: "entities.proto has extra at 6"},
		{call: "migrations.model", args: ["message Other {\n}\n", _facts, _sql], throws: "Order: a table with no message"},
		{call: "migrations.model", args: [_modelProto, _facts, {machines: _machines}], throws: "^Order: 005_create_tables.sql creates no table order: run generate$"},
		{call: "migrations.model", args: [_modelProto, _facts, {machines: _machines, tables: strings.Replace(_tables, "Order_Status ON order (status)", "Order_Status ON order (owner)", -1)}], throws: "^Order: 005_create_tables.sql has no unique index order_status on \\(status\\): run generate$", why: "an index's name is read from 005, never made up"},
		{call: "migrations.model", args: [_modelProto, _facts, {machines: _machines, tables: strings.Replace(_tables, "USING btree (status)", "USING gin (status)", -1)}], throws: "^Order: 005_create_tables.sql has no btree index on order \\(status\\): run generate$"},
		{call: "migrations.model", args: [_modelProto, _facts, {machines: _machines, tables: strings.Replace(_tables, "\"owner\"", "\"owner_id\"", -1)}], throws: "^Order.owner: 005_create_tables.sql has no column order.owner: run generate$"},
		{call: "migrations.model", args: [_modelProto, _facts, {machines: _machines, tables: strings.Replace(_tables, "\"owner\" uuid", "\"owner\" -uuid", -1)}], throws: "^005_create_tables.sql: order.owner has the clause \"-uuid DEFAULT auth_uid\\(\\) NOT NULL REFERENCES app_user\\(id\\) ON DELETE CASCADE\", whose type this does not read: a pronto this plugin does not read"},
		{call: "migrations.model", args: [_modelProto, _facts, {machines: _machines, tables: strings.Replace(_tables, "auth_uid()", "gen_random_uuid()", -1)}], throws: "^Order.owner: its default is auth_uid\\(\\), and 005_create_tables.sql writes gen_random_uuid\\(\\): run generate$", why: "the replay writes the facts' default: one 005 does not write is an app not generated"},
		{call: "migrations.model", args: [_modelProto, {version: 2, entities: {}}], throws: "^.pronto/check-inputs.json: version 2, where this plugin reads version 1: a pronto this plugin does not read \\(rerun bin/pronto-migrations from a pronto-plugins that reads it\\)$"},
		{call: "migrations.model", args: [_modelProto, {version: 1, entities: Order: {server: true, table: "order", fields: [], cel: {}}}], throws: "^.pronto/check-inputs.json: Order has no cel.enums, cel.checks or uniques: a pronto this plugin does not read"},
		{call: "migrations.parseMachines", args: [#"CREATE TRIGGER "trg_order_stage_machine""#], throws: "^010_machines.sql: the trigger trg_order_stage_machine has no check this reader knows: a pronto this plugin does not read"},
	]}
	"005's columns: the type Postgres holds, and the default up to the clause's next part, outside quotes and parentheses": {suite: "migrations", steps: [
		{call: "migrations.parseTables", args: [_tables], holds: {order: {
			columns: {
				id: {sql: "uuid"}
				status: {sql: "text", default: "'draft'"}
				old: {sql: "text", default: "''"}
				total: {sql: "portable_decimal_10_2"}
				owner: {sql: "uuid", default: "auth_uid()"}
			}
			indexes: {idx_order_status: {cols: ["status"], using: "btree"}, order_status: {cols: ["status"], unique: true}}
		}}, why: "an index by the name pronto writes, as Postgres keeps an unquoted one"},
		{call: "migrations.parseTables", args: [#"""
			ALTER TABLE t ADD COLUMN IF NOT EXISTS "a" double precision DEFAULT (1 + 2) NOT NULL;
			ALTER TABLE t ADD COLUMN IF NOT EXISTS "b" text DEFAULT 'it''s NOT NULL' NOT NULL CHECK (b <> '');
			ALTER TABLE t ADD COLUMN IF NOT EXISTS "c" portable_timestamp DEFAULT now() AT TIME ZONE 'utc' UNIQUE;
			ALTER TABLE t ADD COLUMN IF NOT EXISTS "d" time(6);
			ALTER TABLE t ADD COLUMN IF NOT EXISTS "e" integer DEFAULT 0;
			CREATE TABLE IF NOT EXISTS t (
			  "f" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
			  "g" text GENERATED ALWAYS AS (('a' || ' DEFAULT ')) STORED
			);
			"""#], expect: {t: {columns: {
			a: {sql: "double precision", default: "(1 + 2)"}
			b: {sql: "text", default: "'it''s NOT NULL'"}
			c: {sql: "portable_timestamp", default: "now() AT TIME ZONE 'utc'"}
			d: {sql: "time(6)"}
			e: {sql: "integer", default: "0"}
			f: {sql: "uuid", default: "gen_random_uuid()"}
			g: {sql: "text"}
		}, indexes: {}}}, why: "a type of two words, a default in parentheses, one quoting a part's own words, one of several words, a type with its precision, a primary key's default after PRIMARY KEY, and DEFAULT inside a generated expression, which is none"},
		{call: "migrations.parseTables", args: [#"CREATE UNIQUE INDEX IF NOT EXISTS t_ab ON t (a, "b") WHERE a IS NOT NULL;"#], expect: {t: {columns: {}, indexes: {t_ab: {cols: ["a", "b"], unique: true}}}}, why: "several columns, a quoted one, and a partial unique"},
	]}
	"the same model has no changes": {suite: "migrations", steps: [
		{call: "mig.changes", args: [_order, []], expect: []},
	]}
	"a retirement moves the column to what pronto still emits for it: its NOT NULL, unique, reference, machine and indexes go, a default it keeps stays": {suite: "migrations", steps: [
		{call: "mig.changes", args: [_order, [["Order.fields.4", null], ["Order.retired.4", {name: "ref", type: "uuid", required: false}], ["Order.indexes.order_ref_status", null]]], expect: ["retired Order.ref", "optional Order.ref", "unique-dropped Order.ref", "ref-dropped Order.ref", "index-dropped Order index order_ref_status"]},
		{call: "mig.sql", args: [_order, [["Order.fields.4", null], ["Order.retired.4", {name: "ref", type: "uuid", required: false}], ["Order.indexes.order_ref_status", null]]], expect: [
			#"ALTER TABLE "public"."order" ALTER COLUMN "ref" DROP NOT NULL;"#,
			#"ALTER TABLE "public"."order" DROP CONSTRAINT IF EXISTS "order_ref_key";"#,
			#"ALTER TABLE "public"."order" DROP CONSTRAINT IF EXISTS "order_ref_fkey";"#,
			#"DROP INDEX IF EXISTS "public"."order_ref_status";"#,
		]},
		{call: "mig.sql", args: [_order, [["Order.fields.2", null], ["Order.retired.2", {name: "status", type: "string", sql: "text", required: false, default: "'draft'"}]]], expect: [
			#"ALTER TABLE "public"."order" ALTER COLUMN "status" DROP NOT NULL;"#,
			#"DROP TRIGGER IF EXISTS "trg_order_status_machine" ON "public"."order";"#,
			#"ALTER TABLE "public"."order" DROP CONSTRAINT IF EXISTS "order_status_check";"#,
		], why: "the default pronto still emits for the retired column stays, so a fresh database and a live one agree"
		},
		{call: "mig.sql", args: [_order, [["Order.fields.3", null], ["Order.retired.3", {name: "note", type: "string", required: false}]]], expect: [], why: "an optional column with no default needs nothing"},
	]}
	"a rename, a retype, a drop, a reused number and a lost entity are refused: an addition beside a retirement is admitted instead": {suite: "migrations", steps: [
		{call: "mig.changes", args: [_order, [["Order.fields.3.name", "remark"]]], expect: ["field-renamed Order.note"]},
		{call: "mig.plan", args: [_order, [["Order.fields.3.name", "remark"]]], holds: {ops: [], refused: [{at: "Order.note", kind: "field-renamed"}]}},
		{call: "mig.changes", args: [_order, [["Order.fields.6.type", "decimal(10,2)"]]], expect: ["field-retyped Order.total"]},
		{call: "mig.changes", args: [_order, [["Order.fields.6.proto", "double"]]], expect: ["field-retyped Order.total"], why: "the proto's type is the wire's"},
		{call: "mig.plan", args: [_order, [["Order.fields.2.sql", "tsvector"]]], holds: {refused: [{kind: "field-retyped", why: "retyped from text to tsvector: a retype is a new field beside the retired one, which a backfill can copy"}]}, why: "an alias with another column type (tsvector for string) is a retype the replay never applies"},
		{call: "mig.changes", args: [_order, [["Order.fields.3", null]]], expect: ["field-dropped Order.note"]},
		{call: "mig.changes", args: [_order, [["Order.fields.1", null], ["Order.retired.1", {name: "id", type: "uuid", required: false}]]], expect: ["pk-retired Order.id"]},
		{call: "mig.changes", args: [_order, [["Order.fields.3", null], ["Order.retired.3", {name: "remark", type: "string", required: false}]]], expect: ["field-renamed Order.note"], why: "a retirement keeps the name"},
		{call: "mig.changes", args: [_retired, [["Order.retired.7", null], ["Order.fields.7", {name: "legacy", type: "string", proto: "string", required: false}]]], expect: ["field-revived Order.legacy"]},
		{call: "mig.changes", args: [_retired, [["Order.retired.7", null]]], expect: ["retirement-dropped Order.legacy"]},
		{call: "mig.changes", args: [_order, [["Order", null]]], expect: ["entity-dropped Order"]},
		{call: "mig.plan", args: [_order, [["Order", null]]], holds: {refused: [{at: "Order", kind: "entity-dropped", why: "an entity is never removed, as its rows and every reader of them stay: retire each of its fields but the primary key (retired: true) instead, which keeps its table, and make relaxes what the columns held"}]}, why: "the refusal names the path admitted instead"},
		{call: "mig.changes", args: [_order, [["Order", null], ["Purchase", _order.Order]]], expect: ["entity-renamed Order"], why: "the same type id under another name"},
		{call: "mig.changes", args: [_order, [["Order.table", "orders"]]], expect: ["table-renamed Order"]},
		{call: "mig.changes", args: [_order, [["Order.fields.6.generated", "1"]]], expect: ["generated-changed Order.total"]},
		{call: "mig.plan", args: [_order, [["Order.fields.3.name", "remark"], ["Order.fields.4.required", false]]], holds: {refused: [{kind: "field-renamed"}], ops: [{at: "Order.ref"}]}, why: "the plan names every refusal, and make writes nothing while one stands"},
	]}
	"an addition is the replay's, except a required column with no default a migration can compute, on a table that has rows": {suite: "migrations", steps: [
		{call: "mig.changes", args: [_order, [["Order.fields.8", {name: "memo", type: "string", proto: "string", required: false}]]], expect: ["field-added Order.memo"]},
		{call: "mig.plan", args: [_order, [["Order.fields.8", {name: "memo", type: "string", proto: "string", required: false}]]], holds: {ops: [], refused: [], needs: []}},
		{call: "mig.changes", args: [_order, [["Order.fields.8", {name: "placed_at", type: "timestamp", proto: "google.protobuf.Timestamp", required: true, default: "now()"}]]], expect: ["field-added Order.placed_at"]},
		{call: "mig.changes", args: [_order, [["Order.fields.8", {name: "placed_at", type: "timestamp", proto: "google.protobuf.Timestamp", required: true}]]], expect: ["required-added Order.placed_at"]},
		{call: "mig.changes", args: [_order, [["Order.fields.8", {name: "owner_id", type: "uuid", proto: "string", required: true, default: "auth_uid()"}]]], expect: ["required-added Order.owner_id"], why: "auth_uid() is NULL in a migration, as in the replay"},
		{call: "mig.changes", args: [_order, [["Order.fields.8", {name: "owner_id", type: "uuid", proto: "string", required: true, default: "AUTH_UID()"}]]], expect: ["required-added Order.owner_id"], why: "Postgres folds an unquoted name to lowercase, so AUTH_UID() is auth_uid()"},
		{call: "mig.plan", args: [_order, [["Order.fields.8", {name: "placed_at", type: "timestamp", proto: "google.protobuf.Timestamp", required: true}]]], holds: {refused: [{at: "Order.placed_at", kind: "required-added"}]}},
		{call: "mig.changes", args: [_order, [["Refund", {table: "refund", id: "0x02", fields: {"1": {name: "id", type: "uuid", proto: "string", required: true, pk: true}}, retired: {}, indexes: {}}]]], expect: ["entity-added Refund"]},
		{call: "mig.changes", args: [_order, [["Order.indexes.idx_order_stage", {cols: ["stage"], using: "btree"}]]], expect: ["index-added Order index idx_order_stage"]},
		{call: "mig.plan", args: [_order, [["Order.indexes.order_stage", {cols: ["stage"], unique: true}]]], holds: {ops: [], advisories: [{kind: "index-added"}]}, why: "a unique index the replay builds can fail on a duplicate"},
		{call: "mig.changes", args: [_order, [["Order.fields.5.enum", ["new", "paid", "refunded"]]]], expect: ["enum-widened Order.stage"]},
		{call: "mig.changes", args: [_order, [["Order.fields.5.machine", true]]], expect: ["machine-added Order.stage"], why: "010 builds the trigger"},
		{call: "mig.changes", args: [_order, [["Order.fields.3.machine", true], ["Order.fields.3.enum", ["a", "b"]]]], expect: ["machine-added Order.note"], why: "a machine brings its check, which is no change of its own"},
		{call: "mig.plan", args: [_order, [["Order.fields.3.machine", true], ["Order.fields.3.enum", ["a", "b"]]], {}, {trg_order_note_machine: "20261109_0001_a", order_note_check: "20261109_0001_a"}], holds: {refused: [{kind: "rebuilt", why: "trg_order_note_machine was dropped by 20261109_0001_a, which every fresh database still runs after building it: fold 20261109_0001_a (once every database has run it) before building trg_order_note_machine again"}, {kind: "rebuilt", why: "order_note_check was dropped by 20261109_0001_a, which every fresh database still runs after building it: fold 20261109_0001_a (once every database has run it) before building order_note_check again"}], advisories: [{kind: "machine-added"}]}, why: "each name refused once"},
	]}
	"a column added copies what the rows the table held should hold, from the backfill declared for it: a rename spelled as a retirement beside an addition keeps its data": {suite: "migrations", steps: [
		{call: "mig.sql", args: [_order, [["Order.fields.8", {name: "remark", type: "string", proto: "string", required: false}]], {backfill: Order: remark: #""note""#}], expect: [(_move & {tag: "$fill$", where: #""remark" IS NULL AND "remark" IS DISTINCT FROM ("note")"#, update: #"UPDATE "public"."order" SET "remark" = "note" WHERE "remark" IS NULL AND "remark" IS DISTINCT FROM ("note");"#, kept: " AND conname <> ALL (ARRAY['order_remark_check', 'order_remark_type'])"}).text], why: "only rows still holding what the replay gave them (NULL here) and differing from the copy, so a row written or seeded with a value of its own keeps it, and a fresh or copied database runs nothing; every other check is lifted, as in a backfill"},
		{call: "mig.sql", args: [_order, [["Order.fields.8", {name: "remark", type: "string", proto: "string", required: true, default: "''"}]], {backfill: Order: remark: {value: #""note""#, triggers: ["order_final"]}}], expect: [(_move & {tag: "$fill$", where: #""remark" IS NOT DISTINCT FROM ('') AND "remark" IS DISTINCT FROM ("note")"#, update: #"UPDATE "public"."order" SET "remark" = "note" WHERE "remark" IS NOT DISTINCT FROM ('') AND "remark" IS DISTINCT FROM ("note");"#, kept: " AND conname <> ALL (ARRAY['order_remark_check', 'order_remark_type'])", triggers: ["order_final"]}).text], why: "a constant default marks the rows the replay filled; an app's own trigger the copy would trip is named with the value"},
		{call: "mig.plan", args: [_order, [["Order.fields.8", {name: "placed_at", type: "timestamp", proto: "google.protobuf.Timestamp", required: true, default: "now()"}]]], holds: {ops: [], advisories: [{at: "Order.placed_at", kind: "field-added", why: "the replay gives every row the table holds now(), as it reads when the replay runs (the deploy's time, or a new value a row): declare backfill.Order.placed_at, the SQL of the row they should take (another column, say), and make copies it"}]}, why: "a default that reads another value each time fills old rows with the deploy's"},
		{call: "mig.plan", args: [_order, [["Order.fields.8", {name: "placed_at", type: "timestamp", proto: "google.protobuf.Timestamp", required: true, default: "now()"}]], {backfill: Order: placed_at: #""created""#}], holds: {ops: [{at: "Order.placed_at", why: "added: the rows the table held take their copy"}], advisories: [{at: "Order.placed_at", kind: "field-added", why: "the copy cannot tell a row the replay gave now() from one written since with a value of its own, so it copies into every row whose value differs (a seed row, a row written between the replay and the migration): a constant default, or none, lets it touch only the rows the replay filled"}], verdicts: [{at: "Order.placed_at", kind: "field-added", verdict: "ledger"}]}, why: "declared, it is copied, and the change is the ledger's; a volatile default cannot mark the rows the replay filled, which is noted"},
		{call: "mig.plan", args: [_order, [["Order.fields.8", {name: "tag", type: "string", proto: "string", required: true, default: "'random'"}]]], holds: {advisories: []}, why: "a word inside a string literal is no call"},
		{call: "mig.changes", args: [_order, [["Order.fields.8", {name: "who", type: "string", proto: "string", required: true, default: "'current_user'"}]]], expect: ["field-added Order.who"], why: "a session's name inside a literal is a constant, not the session's"},
		{call: "mig.sql", args: [_order, [["Order.fields.8", {name: "code", type: "uuid", proto: "string", required: true, default: "uuidv7()"}]], {backfill: Order: code: #"coalesce("ref", uuidv7())"#}], expect: [(_move & {tag: "$fill$", where: #""code" IS DISTINCT FROM (coalesce("ref", uuidv7()))"#, update: #"UPDATE "public"."order" SET "code" = coalesce("ref", uuidv7()) WHERE "code" IS DISTINCT FROM (coalesce("ref", uuidv7()));"#, kept: " AND conname <> ALL (ARRAY['order_code_check', 'order_code_type'])"}).text], why: "a default that is no literal marks no row the replay filled: the copy touches every row that differs, never none"},
		{call: "mig.plan", args: [_order, [["Order.fields.8", {name: "at", type: "timestamp", proto: "string", required: true, default: "'now'::timestamptz"}]], {backfill: Order: at: #""note"::timestamptz"#}], holds: {advisories: [{at: "Order.at", kind: "field-added"}]}, why: "a time keyword in a literal is read when the statement runs, so it marks nothing either, which is noted"},
		{call: "mig.plan", args: [_order, [["Order.fields.8", {name: "slug", type: "string", proto: "string", required: true, default: "app_slug()"}]], {backfill: Order: slug: #""note""#}], holds: {ops: [{at: "Order.slug", sql: (_move & {tag: "$fill$", where: #""slug" IS DISTINCT FROM ("note")"#, update: #"UPDATE "public"."order" SET "slug" = "note" WHERE "slug" IS DISTINCT FROM ("note");"#, kept: " AND conname <> ALL (ARRAY['order_slug_check', 'order_slug_type'])"}).text}], advisories: [{at: "Order.slug", kind: "field-added"}]}, why: "a function this does not know is no constant: the copy falls back to every row that differs, and says so"},
		{call: "mig.sql", args: [_order, [["Order.fields.8", {name: "data", type: "json", sql: "json", proto: "string", required: true, default: "'{}'"}]], {backfill: Order: data: #"json_build_object('note', "note")"#}], expect: [(_move & {tag: "$fill$", where: #""data"::jsonb IS NOT DISTINCT FROM ('{}')::jsonb AND "data"::jsonb IS DISTINCT FROM (json_build_object('note', "note"))::jsonb"#, update: #"UPDATE "public"."order" SET "data" = json_build_object('note', "note") WHERE "data"::jsonb IS NOT DISTINCT FROM ('{}')::jsonb AND "data"::jsonb IS DISTINCT FROM (json_build_object('note', "note"))::jsonb;"#, kept: " AND conname <> ALL (ARRAY['order_data_check', 'order_data_type'])"}).text], why: "json has no equality: it is compared as jsonb"},
		{call: "mig.plan", args: [_order, [["Order.fields.3", null], ["Order.retired.3", {name: "note", type: "string", required: false}], ["Order.fields.8", {name: "upper", type: "string", proto: "string", required: false, generated: "upper(id::text)"}]]], holds: {needs: [], refused: []}, why: "a generated column beside a retirement takes no backfill, so none is needed"},
		{call: "mig.sql", args: [_order, [["Order.fields.8", {name: "phase", type: "string", proto: "string", required: true, default: "'new'", enum: ["new", "old"], machine: true}]], {backfill: Order: phase: #""stage""#}], expect: [(_move & {
			tag:    "$fill$"
			where:  #""phase" IS NOT DISTINCT FROM ('new') AND "phase" IS DISTINCT FROM ("stage")"#
			update: #"UPDATE "public"."order" SET "phase" = "stage" WHERE "phase" IS NOT DISTINCT FROM ('new') AND "phase" IS DISTINCT FROM ("stage");"#
			kept:   " AND conname <> ALL (ARRAY['order_phase_check', 'order_phase_type'])"
			triggers: ["trg_order_phase_machine"]
		}).text], why: "a copy is not a transition: a machine's column is copied with its trigger off"
		},
		{call: "mig.plan", args: [_order, [["Order.fields.8", {name: "remark", type: "string", proto: "string", required: false}]], {backfill: Order: remark: "$fill$x$fill$"}], holds: {ops: [], refused: [{at: "Order.remark", kind: "backfill", why: "the backfill holds $fill$, its block's own quote"}]}},
		{call: "mig.plan", args: [_order, [["Order.fields.8", {name: "upper", type: "string", proto: "string", required: false, generated: "upper(note)"}]], {backfill: Order: upper: #""note""#}], holds: {ops: [], refused: [{at: "Order.upper", kind: "backfill", why: "a generated column is computed by Postgres: it takes no backfill"}]}},
		{call: "mig.plan", args: [_order, [["Order.fields.3", null], ["Order.retired.3", {name: "note", type: "string", required: false}], ["Order.fields.8", {name: "remark", type: "string", proto: "string", required: false}]]], holds: {ops: [], needs: [{at: "Order.remark", declare: "backfill.Order.remark"}]}, why: "beside a retirement, as a rename is, the copy is a need: a migration made again (rebase) cannot lose it"},
		{call: "mig.plan", args: [_order, [["Order.fields.3", null], ["Order.retired.3", {name: "note", type: "string", required: false}], ["Order.fields.8", {name: "remark", type: "string", proto: "string", required: false}]], {backfill: Order: remark: "DEFAULT"}], holds: {ops: [], needs: [], refused: []}, why: "DEFAULT says the rows keep the replay's default"},
		{call: "mig.plan", args: [_order, [["Order.fields.5.enum", ["new", "settled"]], ["Order.fields.8", {name: "was_stage", type: "string", proto: "string", required: false}]], {carry: Order: stage: values: paid: "settled", backfill: Order: was_stage: #""stage""#}], holds: {ops: [{at: "Order.was_stage"}, {at: "Order.stage"}]}, why: "a copy reads the row as the release before left it, before a carry moves it"},
		{call: "migrations.migration", args: [[{at: "Order.x", why: "a\nDROP INDEX IF EXISTS \"public\".\"idx_x\";", sql: "SELECT 1;"}]], expect: {operations: [{sql: {up: "-- Deferred constraints checked as each statement ends, so the tables can be altered after rows move.\nSET CONSTRAINTS ALL IMMEDIATE;\n\n-- Order.x: a\n-- DROP INDEX IF EXISTS \"public\".\"idx_x\";\nSELECT 1;"}}]}, why: "every line of a why is a comment"},
		{call: "migrations.droppedBy", args: [[{name: "m", json: operations: [{sql: up: "-- DROP INDEX IF EXISTS \"public\".\"idx_x\";\nSELECT 1;"}]}]], expect: {}, why: "a comment drops nothing"},
		{call: "migrations.migration", args: [[{at: "Order.x", why: "a\rDROP TABLE x;", sql: "SELECT 1;"}]], expect: {operations: [{sql: {up: "-- Deferred constraints checked as each statement ends, so the tables can be altered after rows move.\nSET CONSTRAINTS ALL IMMEDIATE;\n\n-- Order.x: a\n-- DROP TABLE x;\nSELECT 1;"}}]}, why: "Postgres ends a comment at a carriage return too"},
		{call: "mig.plan", args: [_order, [["Order.fields.8", {name: "remark", type: "string", proto: "string", required: false}]], {backfill: Order: remark: {value: #""note""#, triggers: ["order final"]}}], holds: {ops: [], refused: [{at: "Order.remark", kind: "backfill", why: "triggers names order final, which is no trigger's name (letters, digits, _ and $)"}]}},
		{call: "mig.plan", args: [_order, _stageNarrowed, {carry: Order: stage: {values: paid: "settled", triggers: ["x$carry$"]}}], holds: {ops: [], refused: [{kind: "carry"}]}, why: "a trigger's name is quoted inside the carry's block too"},
	]}
	"a declaration no change since the snapshot reads is refused, so none is read into a later change": {suite: "migrations", steps: [
		{call: "mig.plan", args: [_order, [["Order.fields.4.required", false]], {backfill: Order: note: "''"}], holds: {refused: [{at: "Order.note", kind: "declaration", why: "schemaMigrations.backfill.Order.note is for no change since the snapshot: remove it, as a declaration serves the migration it was written for, and one left would be read into a later change to Order.note"}]}},
		{call: "mig.plan", args: [_order, [["Order.fields.4.required", false]], {carry: Order: stage: values: paid: "new"}], holds: {refused: [{at: "Order.stage", kind: "declaration"}]}},
		{call: "mig.plan", args: [_order, [["Order.fields.3.required", false], ["Order.fields.3.default", "'x'"]], {backfill: Order: note: "''"}], holds: {refused: [{at: "Order.note", kind: "declaration"}]}, why: "another change to the same column reads no backfill, so one left there is still refused"},
		{call: "mig.plan", args: [_order, [["Order.fields.5.default", "'paid'"]], {carry: Order: stage: values: paid: "new"}], holds: {refused: [{at: "Order.stage", kind: "declaration"}]}, why: "a default change reads no carry"},
		{call: "mig.plan", args: [_order, [["Order.fields.8", {name: "placed_at", type: "timestamp", proto: "google.protobuf.Timestamp", required: true}]], {backfill: Order: placed_at: "now()"}], holds: {refused: [{at: "Order.placed_at", kind: "required-added"}]}, why: "a declaration at a refused change is that change's, refused once"},
	]}
	"a migration records the declarations it was made with, and a migration made again reads them where the app declares none": {suite: "migrations", steps: [
		{call: "mig.plan", args: [_order, [["Order.fields.8", {name: "remark", type: "string", proto: "string", required: false}]], {backfill: Order: remark: #""note""#}], holds: {used: {backfill: Order: remark: #""note""#}}},
		{call: "migrations.migration", args: [[{at: "Order.remark", why: "w", sql: "SELECT 1;"}], {backfill: Order: remark: #""note""#}]},
		{keep: "m"},
		{call: "migrations.declaredIn", args: ["$m"], expect: {backfill: Order: remark: #""note""#}},
		{call: "migrations.declaredIn", args: [{operations: [{sql: up: "SELECT 1;"}]}], expect: {}},
		{call: "mig.plan", args: [_order, [["Order.fields.8", {name: "remark", type: "string", proto: "string", required: false}]], {}, {}, {backfill: Order: remark: #""note""#}], holds: {ops: [{at: "Order.remark"}], refused: []}, why: "rebase: the copy the branch's migration had is made again"},
		{call: "mig.plan", args: [_order, [["Order.fields.4.required", false]], {}, {}, {backfill: Order: gone: #""note""#}], holds: {refused: []}, why: "an inherited declaration no change reads is dropped, not refused"},
	]}
	"every kind of change has a rule, and one with none is an error, never the replay's": {suite: "migrations", steps: [
		{call: "migrations.plan", args: [[{kind: "column-moved", entity: "Order", table: "order", field: "x"}]], throws: "^Order.x: a change of kind column-moved, which this plugin has no rule for$"},
		{call: "migrations.verdict", args: [{kind: "column-moved", entity: "Order"}], throws: "a change of kind column-moved"},
		{call: "migrations.verdict", args: [{kind: "field-added", entity: "Order", field: "x"}], expect: "replay"},
	]}
	"every op says the names it drops and builds for good, and droppedBy reads the same from its migration": {suite: "migrations", steps: [
		{call: "mig.names", args: [_order, [
			["Order.fields.4", null], ["Order.retired.4", {name: "ref", type: "uuid", required: false}],
			["Order.indexes.order_ref_status", null],
			["Order.fields.6.check", null],
			["Order.fields.2.machine", null],
			["Order.indexes.idx_order_note", {cols: ["note", "stage"], using: "btree"}],
			["Order.fields.3.unique", true],
			["Order.fields.3.ref", "customer"],
			["Order.fields.5.enum", ["new", "settled"]],
		], {carry: Order: stage: values: paid: "settled"}], expect: {
			said: ["order_ref_fkey", "order_ref_key", "order_ref_status", "order_total_check", "trg_order_status_machine"]
			read: ["order_ref_fkey", "order_ref_key", "order_ref_status", "order_total_check", "trg_order_status_machine"]
		}},
		{call: "mig.names", args: [_order, [["Order.fields.3.unique", true], ["Order.fields.3.ref", "customer"]], {}, ["order_note_key", "order_note_fkey", "order_stage_check"]], expect: {
			said: ["order_stage_check"]
			read: ["order_stage_check"]
		}, why: "a unique and a reference built again are no longer dropped, by either reading"},
	]}
	"a column made required fills its NULLs, then is tightened: from what the app declares, else its default, else it is a need": {suite: "migrations", steps: [
		{call: "mig.plan", args: [_order, [["Order.fields.3.required", true]]], holds: {ops: [], needs: [{at: "Order.note", declare: "backfill.Order.note"}]}},
		{call: "mig.sql", args: [_order, [["Order.fields.3.required", true]], {backfill: Order: note: {value: "''", triggers: ["order_final"]}}], expect: [(_move & {tag: "$fill$", where: #""note" IS NULL"#, update: #"UPDATE "public"."order" SET "note" = '' WHERE "note" IS NULL;"#, kept: " AND conname <> ALL (ARRAY['order_note_check', 'order_note_type'])", triggers: ["order_final"]}).text, #"ALTER TABLE "public"."order" ALTER COLUMN "note" SET NOT NULL;"#], why: "a fill names the triggers it trips as a copy does"},
		{call: "mig.sql", args: [_order, [["Order.fields.3.required", true]], {backfill: Order: note: "''"}], expect: [(_fillNote & {value: "''"}).text, #"ALTER TABLE "public"."order" ALTER COLUMN "note" SET NOT NULL;"#], why: "a database with no NULL row runs nothing; every other check is lifted around the fill, as an update is checked against all of them, and the column's own stays, as the value it fills is the model's"},
		{call: "mig.sql", args: [_order, [["Order.fields.3.required", true], ["Order.fields.3.default", "'none'"]]], expect: [
			#"ALTER TABLE "public"."order" ALTER COLUMN "note" SET DEFAULT 'none';"#,
			(_fillNote & {value: "'none'"}).text,
			#"ALTER TABLE "public"."order" ALTER COLUMN "note" SET NOT NULL;"#,
		]},
		{call: "mig.plan", args: [_order, [["Order.fields.3.required", true], ["Order.fields.3.default", "auth_uid()"]]], holds: {needs: [{declare: "backfill.Order.note"}]}, why: "a session's default fills nothing in a migration"},
		{call: "mig.plan", args: [_order, [["Order.fields.3.required", true]], {backfill: Order: note: "$fill$x$fill$"}], holds: {ops: [], refused: [{at: "Order.note", kind: "backfill", why: "the backfill holds $fill$, its block's own quote"}]}},
	]}
	"a column made optional, and a default changed or removed, alter the column in place": {suite: "migrations", steps: [
		{call: "mig.sql", args: [_order, [["Order.fields.4.required", false]]], expect: [#"ALTER TABLE "public"."order" ALTER COLUMN "ref" DROP NOT NULL;"#]},
		{call: "mig.sql", args: [_order, [["Order.fields.2.default", "'open'"]]], expect: [#"ALTER TABLE "public"."order" ALTER COLUMN "status" SET DEFAULT 'open';"#]},
		{call: "mig.sql", args: [_order, [["Order.fields.2.default", null]]], expect: [#"ALTER TABLE "public"."order" ALTER COLUMN "status" DROP DEFAULT;"#]},
		{call: "mig.sql", args: [_order, [["Order.fields.4.required", false]], {schema: "shop"}], expect: [#"ALTER TABLE "shop"."order" ALTER COLUMN "ref" DROP NOT NULL;"#], why: "the schema the app declares"},
	]}
	"a value gone from an enum is carried, only where a row holds one: what each becomes, or the row's new columns, else it is a need": {suite: "migrations", steps: [
		{call: "mig.changes", args: [_order, _stageNarrowed], expect: ["enum-narrowed Order.stage"]},
		{call: "mig.plan", args: [_order, _stageNarrowed], holds: {ops: [], needs: [{at: "Order.stage", declare: "carry.Order.stage"}]}},
		{call: "mig.sql", args: [_order, _stageNarrowed, _carryValues], expect: [(_move & {tag: "$carry$", where: #""stage" IN ('paid')"#, update: #"UPDATE "public"."order" SET "stage" = CASE "stage" WHEN 'paid' THEN 'settled' END WHERE "stage" IN ('paid');"#}).text], why: "a fresh database, or one carried already, holds no such row and runs nothing; every check on the table is lifted around the move and put back NOT VALID: Postgres checks a row it updates against every check, even one NOT VALID, which a row written before the replay restated it may break, and a database that skipped releases holds a later migration's check, which an earlier carry's destination is outside"},
		{call: "mig.sql", args: [_order, _stageNarrowed, {carry: Order: stage: {set: {stage: "'settled'", status: "'open'"}, triggers: ["trg_order_status_machine"]}}], expect: [(_move & {
			tag:    "$carry$"
			where:  #""stage" IN ('paid')"#
			update: #"UPDATE "public"."order" SET "stage" = 'settled', "status" = 'open' WHERE "stage" IN ('paid');"#
			triggers: ["trg_order_status_machine"]
		}).text], why: "set also moves status, a machine's column, with its trigger off where it exists"
		},
		{call: "mig.plan", args: [_order, [["Order.fields.2.enum", ["open", "closed"]]], {carry: Order: status: values: draft: "open"}], holds: {ops: [{at: "Order.status"}], refused: []}, why: "a machine's own column needs no trigger off: its chart lets a state it does not know move"},
	]}
	"a carry that cannot be applied is refused, saying why": {suite: "migrations", steps: [
		{call: "mig.plan", args: [_order, _stageNarrowed, {carry: Order: stage: values: {}}], holds: {refused: [{kind: "carry", why: "values says nothing for 'paid'"}]}},
		{call: "mig.plan", args: [_order, _stageNarrowed, {carry: Order: stage: values: paid: "gone"}], holds: {refused: [{why: "values carries to what it does not admit: paid → gone"}]}},
		{call: "mig.plan", args: [_order, _stageNarrowed, {carry: Order: stage: set: note: "'x'"}], holds: {refused: [{why: "the carry gives stage no value: name values, or set stage"}]}},
		{call: "mig.plan", args: [_order, _stageNarrowed, {carry: Order: stage: {values: paid: "settled", set: stage: "'new'"}}], holds: {refused: [{why: "both values and set give stage its value"}]}},
		{call: "mig.plan", args: [_order, _stageNarrowed, {carry: Order: stage: set: {stage: "'settled'", status: "'open'"}}], holds: {refused: [{why: "set moves status, which a machine guards: list trg_order_status_machine in triggers"}]}},
		{call: "mig.plan", args: [_order, _stageNarrowed, {carry: Order: stage: {values: paid: "settled", triggers: ["order_final"]}}], holds: {refused: [], ops: [{at: "Order.stage"}]}, why: "any trigger on the table may be listed, an app's own too (one refusing to change a final row)"},
	]}
	"a migration relaxes, then moves rows, then tightens, whatever order the columns come in": {suite: "migrations", steps: [
		{call: "mig.plan", args: [_order, [["Order.fields.3.required", true], ["Order.fields.5.enum", ["new", "settled"]], ["Order.fields.6.check", null]], {backfill: Order: note: "''", carry: Order: stage: set: {stage: "'settled'", total: "-1"}}], holds: {ops: [
				{at: "Order.total", why: "its check removed"},
				{at: "Order.note", why: "made required: its NULL rows filled"},
				{at: "Order.stage"},
				{at: "Order.note", why: "made required"},
		]}, why: "the carry writes a total the check it drops would refuse, and the column made required is tightened last"
		},
	]}
	"checks, machines, uniques, references and indexes the replay never removes or rebuilds are the ledger's": {suite: "migrations", steps: [
		{call: "mig.sql", args: [_order, [["Order.fields.6.check", null]]], expect: [#"ALTER TABLE "public"."order" DROP CONSTRAINT IF EXISTS "order_total_check";"#]},
		{call: "mig.sql", args: [_order, [["Order.fields.5.enum", null]]], expect: [#"ALTER TABLE "public"."order" DROP CONSTRAINT IF EXISTS "order_stage_check";"#]},
		{call: "mig.sql", args: [_order, [["Order.fields.2.machine", null]]], expect: [#"DROP TRIGGER IF EXISTS "trg_order_status_machine" ON "public"."order";"#]},
		{call: "mig.sql", args: [_order, [["Order.fields.4.unique", null]]], expect: [#"ALTER TABLE "public"."order" DROP CONSTRAINT IF EXISTS "order_ref_key";"#]},
		{call: "mig.sql", args: [_order, [["Order.fields.3.unique", true]]], expect: [#"ALTER TABLE "public"."order" DROP CONSTRAINT IF EXISTS "order_note_key", ADD CONSTRAINT "order_note_key" UNIQUE ("note");"#], why: "a constraint, as pronto's inline UNIQUE makes, so a later drop finds it"},
		{call: "mig.plan", args: [_order, [["Order.fields.3.unique", true]]], holds: {advisories: [{kind: "unique-added"}]}},
		{call: "mig.sql", args: [_order, [["Order.fields.4.ref", null]]], expect: [#"ALTER TABLE "public"."order" DROP CONSTRAINT IF EXISTS "order_ref_fkey";"#]},
		{call: "mig.sql", args: [_order, [["Order.fields.3.ref", "customer"]]], expect: [#"ALTER TABLE "public"."order" DROP CONSTRAINT IF EXISTS "order_note_fkey", ADD CONSTRAINT "order_note_fkey" FOREIGN KEY ("note") REFERENCES "public"."customer" ("id") ON DELETE CASCADE NOT VALID;"#]},
		{call: "mig.changes", args: [_order, [["Order.fields.4.ref", "client"]]], expect: ["ref-dropped Order.ref", "ref-added Order.ref"]},
		{call: "mig.sql", args: [_order, [["Order.indexes.idx_order_note", {cols: ["note", "stage"], using: "btree"}]]], expect: [#"DROP INDEX IF EXISTS "public"."idx_order_note";"#, #"CREATE INDEX "idx_order_note" ON "public"."order" USING btree ("note", "stage");"#]},
	]}
	"a name a migration dropped is not built again by the replay until that migration is folded": {suite: "migrations", steps: [
		{call: "migrations.droppedBy", args: [[
			{name: "20261109_0001_a", json: operations: [{sql: up: #"DROP INDEX IF EXISTS "public"."idx_order_note";"# + "\n" + #"ALTER TABLE "public"."order" DROP CONSTRAINT IF EXISTS "order_note_key", ADD CONSTRAINT "order_note_key" UNIQUE ("note");"#}]},
			{name: "20261109_0002_b", json: operations: [{sql: up: #"DROP TRIGGER IF EXISTS "trg_order_stage_machine" ON "public"."order";"# + "\n" + #"DROP INDEX IF EXISTS "public"."idx_order_note";"#}]},
		]], expect: {idx_order_note: "20261109_0001_a", trg_order_stage_machine: "20261109_0002_b"}, why: "a name the same migration builds again is not dropped"
		},
		{call: "migrations.droppedBy", args: [[
			{name: "20261109_0001_a", json: operations: [{sql: up: #"ALTER TABLE "public"."order" DROP CONSTRAINT IF EXISTS "order_note_key";"#}]},
			{name: "20261109_0002_b", json: operations: [{sql: up: #"ALTER TABLE "public"."order" DROP CONSTRAINT IF EXISTS "order_note_key", ADD CONSTRAINT "order_note_key" UNIQUE ("note");"#}]},
		]], expect: {}, why: "a name a later migration builds again is no longer dropped"
		},
		{call: "mig.dropped", args: [_order, [["Order.fields.6.check", null], ["Order.fields.5.enum", ["new", "settled"]]], {carry: Order: stage: set: {stage: "'settled'", total: "0"}}], expect: {order_total_check: "m"}, why: "a carry puts back the check it lifted, so a check the same migration drops for good stays dropped"},
		{call: "mig.plan", args: [_order, [["Order.indexes.idx_order_stage", {cols: ["stage"], using: "btree"}]], {}, {idx_order_stage: "20261109_0002_b"}], holds: {refused: [{kind: "rebuilt", why: "idx_order_stage was dropped by 20261109_0002_b, which every fresh database still runs after building it: fold 20261109_0002_b (once every database has run it) before building idx_order_stage again"}]}},
		{call: "mig.plan", args: [_order, [["Order.fields.3.check", "note <> ''"]], {}, {order_note_check: "20261109_0001_a"}], holds: {refused: [{kind: "rebuilt"}], advisories: [{kind: "check-added"}]}},
		{call: "mig.plan", args: [_order, [["Order.fields.5.machine", true]], {}, {trg_order_stage_machine: "20261109_0002_b"}], holds: {refused: [{kind: "rebuilt", why: "trg_order_stage_machine was dropped by 20261109_0002_b, which every fresh database still runs after building it: fold 20261109_0002_b (once every database has run it) before building trg_order_stage_machine again"}]}, why: "a machine put back on a column whose states did not change"},
	]}
	"a check changed or added is advisory: the replay adds it NOT VALID": {suite: "migrations", steps: [
		{call: "mig.plan", args: [_order, [["Order.fields.6.check", "total > 0"]]], holds: {ops: [], advisories: [{at: "Order.total", kind: "check-changed"}]}},
		{call: "mig.plan", args: [_order, [["Order.fields.3.check", "note <> ''"]]], holds: {ops: [], advisories: [{at: "Order.note", kind: "check-added"}]}},
	]}
	"a migration is pgroll's: one raw SQL operation, every change in it saying where and why": {suite: "migrations", steps: [
		{call: "migrations.migration", args: [[{at: "Order.ref", why: "no longer required", sql: "ALTER TABLE x;"}, {at: "Order.note", why: "made required", sql: "ALTER TABLE y;"}]], expect: {operations: [{sql: {up: "-- Deferred constraints checked as each statement ends, so the tables can be altered after rows move.\nSET CONSTRAINTS ALL IMMEDIATE;\n\n-- Order.ref: no longer required\nALTER TABLE x;\n\n-- Order.note: made required\nALTER TABLE y;"}}]}, why: "pgroll refuses a raw SQL operation beside others, and runs one in one transaction, where a deferred constraint trigger's pending events would stop an ALTER TABLE"},
		{call: "migrations.nextName", args: [[], "relax_ref", "20261109"], expect: "20261109_0001_relax_ref", why: "the day it is made, its count that day, and what it does"},
		{call: "migrations.nextName", args: [["20261108_0007_a", "20261109_0001_b", "20261109_0002_c"], "d", "20261109"], expect: "20261109_0003_d"},
		{call: "migrations.nextName", args: [["20261109_0002_c"], "e", "20261110"], expect: "20261110_0001_e", why: "the count starts again each day"},
		{call: "migrations.nextName", args: [["20261109_0004_folded"], "f", "20261109", ["01_hand"]], expect: "20261109_0005_f", why: "the count goes on after a migration folded away, and a migration written by hand that sorts before stays before"},
		{call: "migrations.nextName", args: [[], "a", "20261109", ["20261110_0001_x"]], expect: "20261110_0002_a", why: "a later day already used (a machine in a zone ahead) is taken, so the name sorts after it, as pgroll's runner needs"},
		{call: "migrations.nextName", args: [[], "a", "20261109", ["zz_hand"]], throws: "20261109_0001_a sorts before the app's migration zz_hand", why: "no dated name can follow it"},
		{call: "migrations.nextName", args: [[], "Relax-Ref", "20261109"], throws: "lowercase letters, digits and _", why: "pgroll's ledger takes these names"},
		{call: "migrations.nextName", args: [[], "0001", "20261109"], throws: "starting with a letter", why: "the name says what the migration does"},
		{call: "migrations.nextName", args: [[], "a", "2026-11-09"], throws: "YYYYMMDD"},
	]}
	"a migration's name is the day, its count and what it does; every other .json the ledger would embed is a stray": {suite: "migrations", steps: [
		{call: "migrations.isName", args: ["20261109_0001_retire_ref"], expect: true},
		{call: "migrations.isName", args: ["20261109_0001_Retire"], expect: false},
		{call: "migrations.isName", args: ["01_hand"], expect: false},
		{call: "migrations.slugOf", args: ["20261109_0001_retire_ref"], expect: "retire_ref"},
		{call: "migrations.strays", args: [["snapshot.json", "migrations.sum", "migrate.ts", "20261109_0001_a.json", "notes.json", "01_hand.json"]], expect: ["notes.json", "01_hand.json"], why: "the ledger embeds every .json but the snapshot, so a file that is no migration would reach pgroll"},
	]}
	"the sum finds a file edited, removed or not written by make, and keeps the migration folded last": {suite: "migrations", steps: [
		{call: "migrations.sum", args: [[{name: "snapshot.json", text: "{}\n"}, {name: "20261109_0001_a.json", text: "a"}]]},
		{keep: "s"},
		{use: "s", matches: "^h1:[A-Za-z0-9+/=]+\\n20261109_0001_a.json h1:[A-Za-z0-9+/=]+\\nsnapshot.json h1:[A-Za-z0-9+/=]+\\n$"},
		{call: "migrations.verify", args: ["$s", [{name: "snapshot.json", text: "{}\n"}, {name: "20261109_0001_a.json", text: "a"}]], expect: []},
		{call: "migrations.verify", args: ["$s", [{name: "snapshot.json", text: "{}\n"}, {name: "20261109_0001_a.json", text: "b"}]], expect: ["20261109_0001_a.json: edited since make wrote it"]},
		{call: "migrations.verify", args: ["$s", [{name: "snapshot.json", text: "{}\n"}]], expect: ["20261109_0001_a.json: removed"]},
		{call: "migrations.verify", args: ["$s", [{name: "snapshot.json", text: "{}\n"}, {name: "20261109_0001_a.json", text: "a"}, {name: "20261109_0002_b.json", text: "b"}]], expect: ["20261109_0002_b.json: not made by make"]},
		{call: "migrations.sum", args: [[{name: "snapshot.json", text: "{}\n"}], "20261109_0001_a"]},
		{keep: "f"},
		{call: "migrations.foldedOf", args: ["$f"], expect: "20261109_0001_a"},
		{call: "migrations.verify", args: ["$f", [{name: "snapshot.json", text: "{}\n"}]], expect: []},
	]}
	"the snapshot is the model with its format, keys sorted and field numbers as numbers; an older format is upgraded first, a newer one refused": {suite: "migrations", steps: [
		{call: "migrations.snapshot", args: [{b: {fields: {"10": {}, "9": {}}}, a: 1}], expect: "{\n  \"format\": 2,\n  \"model\": {\n    \"a\": 1,\n    \"b\": {\n      \"fields\": {\n        \"9\": {},\n        \"10\": {}\n      }\n    }\n  }\n}\n"},
		{call: "migrations.fromSnapshot", args: ["{\"format\": 2, \"model\": {\"A\": {}}}"], expect: {A: {}}},
		{call: "migrations.fromSnapshot", args: ["{\"format\": 1, \"model\": {}}"], throws: "^migrations/snapshot.json is format 1, where this plugin reads format 2: run `deno run --no-config -A migrations/migrate.ts upgrade`$"},
		{call: "migrations.fromSnapshot", args: ["{\"format\": 3, \"model\": {}}"], throws: "^migrations/snapshot.json: format 3: a pronto this plugin does not read"},
	]}
	"upgrade carries an older snapshot to this format from the model at the commit it was taken at, and refuses one that is not that model": {suite: "migrations", steps: [
		{call: "mig.upgrade", args: [_order, [["Order.fields.2.default", null]]], holds: {from: 1, model: Order: fields: "2": default: "'draft'"}, why: "format 2 records a machine's default, which format 1 did not"},
		{call: "mig.upgrade", args: [_order, [["Order.fields.2.default", null], ["Order.fields.3.required", true]]], throws: "differ at Order.fields.3.required\\): name the commit the snapshot was taken at \\(upgrade --from <ref>\\)$", why: "a snapshot that is not the model at that commit is not guessed into it"},
		{call: "mig.upgrade", args: [_order, [["Order.fields.5.default", null]]], throws: "differ at Order.fields.5.default", why: "only a machine's default is what format 2 adds"},
		{call: "mig.upgrade", args: [_order, [], 2], throws: "format 2 already"},
	]}
}
