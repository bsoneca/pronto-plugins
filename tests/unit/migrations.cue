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
				{name: "status", ordinal: 2, retired: false, type: "text", pk: false, required: true, default: "'draft'"},
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

_t: #""public"."order""#
_trg: "IF EXISTS (SELECT FROM pg_trigger WHERE tgrelid = '\(_t)'::regclass AND tgname = 'trg_order_status_machine')"

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
		{call: "migrations.model", args: [_modelProto, _facts, _machines], holds: {Order: {
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
		}}, why: "an alias is its type (text is string), a column keeps the type Postgres holds, a decimal carries its precision and scale, and an index's name is as Postgres keeps an unquoted one"},
		{get: "Draft", matches: "^undefined$", why: "an entity with no table is not the database's"},
	]}
	"a proto and facts that disagree, or a pronto this does not read, are refused, never guessed": {suite: "migrations", steps: [
		{call: "migrations.model", args: ["message Order {\n  optional string id = 1;\n  optional string state = 2;\n  reserved 3;\n  reserved \"old\";\n  optional string total = 4;\n  optional string owner = 5;\n}\n", _facts], throws: "Order.status: entities.proto has state at 2: run generate"},
		{call: "migrations.model", args: ["message Order {\n  optional string id = 1;\n  optional string status = 2;\n  optional string total = 4;\n  optional string owner = 5;\n}\n", _facts], throws: "Order.old: retired, and entities.proto does not reserve 3"},
		{call: "migrations.model", args: ["message Order {\n  optional string id = 1;\n  optional string status = 2;\n  reserved 3;\n  reserved \"old\";\n  optional string total = 4;\n  optional string owner = 5;\n  optional string extra = 6;\n}\n", _facts], throws: "entities.proto has extra at 6"},
		{call: "migrations.model", args: ["message Other {\n}\n", _facts], throws: "Order: a table with no message"},
		{call: "migrations.model", args: [_modelProto, {version: 2, entities: {}}], throws: "version 2; this plugin reads version 1"},
		{call: "migrations.model", args: [_modelProto, {version: 1, entities: Order: {server: true, table: "order", fields: [], cel: {}}}], throws: "has no cel.enums, cel.checks or uniques"},
		{call: "migrations.parseMachines", args: [#"CREATE TRIGGER "trg_order_stage_machine""#], throws: "trg_order_stage_machine has no check this reader knows"},
	]}
	"the same model has no changes": {suite: "migrations", steps: [
		{call: "mig.changes", args: [_order, []], expect: []},
	]}
	"a retirement moves the column to what pronto still emits for it: its NOT NULL, unique, reference, machine and indexes go, a default it keeps stays": {suite: "migrations", steps: [
		{call: "mig.changes", args: [_order, [["Order.fields.4", null], ["Order.retired.4", {name: "ref", type: "uuid", required: false}], ["Order.indexes.order_ref_status", null]]], expect: ["retired Order.ref", "optional Order.ref", "unique-dropped Order.ref", "ref-dropped Order.ref", "index-dropped Order order_ref_status"]},
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
		], why: "the default pronto still emits for the retired column stays, so a fresh database and a live one agree"},
		{call: "mig.sql", args: [_order, [["Order.fields.3", null], ["Order.retired.3", {name: "note", type: "string", required: false}]]], expect: [], why: "an optional column with no default needs nothing"},
	]}
	"a rename, a retype, a drop, a reused number and a lost entity are refused: an addition beside a retirement is admitted instead": {suite: "migrations", steps: [
		{call: "mig.changes", args: [_order, [["Order.fields.3.name", "remark"]]], expect: ["field-renamed Order.note"]},
		{call: "mig.plan", args: [_order, [["Order.fields.3.name", "remark"]]], holds: {ops: [], refused: [{at: "Order.note", kind: "field-renamed"}]}},
		{call: "mig.changes", args: [_order, [["Order.fields.6.type", "decimal(10,2)"]]], expect: ["field-retyped Order.total"]},
		{call: "mig.changes", args: [_order, [["Order.fields.6.proto", "double"]]], expect: ["field-retyped Order.total"], why: "the proto's type is the wire's"},
		{call: "mig.plan", args: [_order, [["Order.fields.2.sql", "tsvector"]]], holds: {refused: [{kind: "field-retyped", why: "retyped from text to tsvector: a retype is a new field beside the retired one"}]}, why: "an alias with another column type (tsvector for string) is a retype the replay never applies"},
		{call: "mig.changes", args: [_order, [["Order.fields.3", null]]], expect: ["field-dropped Order.note"]},
		{call: "mig.changes", args: [_order, [["Order.fields.1", null], ["Order.retired.1", {name: "id", type: "uuid", required: false}]]], expect: ["pk-retired Order.id"]},
		{call: "mig.changes", args: [_order, [["Order.fields.3", null], ["Order.retired.3", {name: "remark", type: "string", required: false}]]], expect: ["field-renamed Order.note"], why: "a retirement keeps the name"},
		{call: "mig.changes", args: [_retired, [["Order.retired.7", null], ["Order.fields.7", {name: "legacy", type: "string", proto: "string", required: false}]]], expect: ["field-revived Order.legacy"]},
		{call: "mig.changes", args: [_retired, [["Order.retired.7", null]]], expect: ["retirement-dropped Order.legacy"]},
		{call: "mig.changes", args: [_order, [["Order", null]]], expect: ["entity-dropped Order"]},
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
		{call: "mig.plan", args: [_order, [["Order.fields.8", {name: "placed_at", type: "timestamp", proto: "google.protobuf.Timestamp", required: true}]]], holds: {refused: [{at: "Order.placed_at", kind: "required-added"}]}},
		{call: "mig.changes", args: [_order, [["Refund", {table: "refund", id: "0x02", fields: {"1": {name: "id", type: "uuid", proto: "string", required: true, pk: true}}, retired: {}, indexes: {}}]]], expect: ["entity-added Refund"]},
		{call: "mig.changes", args: [_order, [["Order.indexes.idx_order_stage", {cols: ["stage"], using: "btree"}]]], expect: ["index-added Order idx_order_stage"]},
		{call: "mig.plan", args: [_order, [["Order.indexes.order_stage", {cols: ["stage"], unique: true}]]], holds: {ops: [], advisories: [{kind: "index-added"}]}, why: "a unique index the replay builds can fail on a duplicate"},
		{call: "mig.changes", args: [_order, [["Order.fields.5.enum", ["new", "paid", "refunded"]]]], expect: ["enum-widened Order.stage"]},
		{call: "mig.changes", args: [_order, [["Order.fields.5.machine", true]]], expect: ["machine-added Order.stage"], why: "010 builds the trigger"},
	]}
	"a column made required fills its NULLs, then is tightened: from what the app declares, else its default, else it is a need": {suite: "migrations", steps: [
		{call: "mig.plan", args: [_order, [["Order.fields.3.required", true]]], holds: {ops: [], needs: [{at: "Order.note", declare: "backfill.Order.note"}]}},
		{call: "mig.sql", args: [_order, [["Order.fields.3.required", true]], {backfill: Order: note: "''"}], expect: [#"UPDATE "public"."order" SET "note" = '' WHERE "note" IS NULL;"#, #"ALTER TABLE "public"."order" ALTER COLUMN "note" SET NOT NULL;"#]},
		{call: "mig.sql", args: [_order, [["Order.fields.3.required", true], ["Order.fields.3.default", "'none'"]]], expect: [
			#"ALTER TABLE "public"."order" ALTER COLUMN "note" SET DEFAULT 'none';"#,
			#"UPDATE "public"."order" SET "note" = 'none' WHERE "note" IS NULL;"#,
			#"ALTER TABLE "public"."order" ALTER COLUMN "note" SET NOT NULL;"#,
		]},
		{call: "mig.plan", args: [_order, [["Order.fields.3.required", true], ["Order.fields.3.default", "auth_uid()"]]], holds: {needs: [{declare: "backfill.Order.note"}]}, why: "a session's default fills nothing in a migration"},
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
		{call: "mig.sql", args: [_order, _stageNarrowed, _carryValues], expect: [strings.Join([
			"DO $carry$",
			"BEGIN",
			#"  IF EXISTS (SELECT FROM "public"."order" WHERE "stage" IN ('paid')) THEN"#,
			#"    UPDATE "public"."order" SET "stage" = CASE "stage" WHEN 'paid' THEN 'settled' END WHERE "stage" IN ('paid');"#,
			"  END IF;",
			"END $carry$;",
		], "\n")], why: "a fresh database, or one carried already, holds no such row and runs nothing"},
		{call: "mig.sql", args: [_order, _stageNarrowed, {carry: Order: stage: {set: {stage: "'settled'", status: "'open'"}, triggers: ["trg_order_status_machine"]}}], expect: [strings.Join([
			"DO $carry$",
			"BEGIN",
			#"  IF EXISTS (SELECT FROM "public"."order" WHERE "stage" IN ('paid')) THEN"#,
			"    \(_trg) THEN ALTER TABLE \(_t) DISABLE TRIGGER \"trg_order_status_machine\"; END IF;",
			#"    UPDATE "public"."order" SET "stage" = 'settled', "status" = 'open' WHERE "stage" IN ('paid');"#,
			"    \(_trg) THEN ALTER TABLE \(_t) ENABLE TRIGGER \"trg_order_status_machine\"; END IF;",
			"  END IF;",
			"END $carry$;",
		], "\n")], why: "set also moves status, a machine's column, with its trigger off where it exists"},
		{call: "mig.plan", args: [_order, [["Order.fields.2.enum", ["open", "closed"]]], {carry: Order: status: values: draft: "open"}], holds: {ops: [{at: "Order.status"}], refused: []}, why: "a machine's own column needs no trigger off: its chart lets a state it does not know move"},
	]}
	"a carry that cannot be applied is refused, saying why": {suite: "migrations", steps: [
		{call: "mig.plan", args: [_order, _stageNarrowed, {carry: Order: stage: values: {}}], holds: {refused: [{kind: "carry", why: "values says nothing for 'paid'"}]}},
		{call: "mig.plan", args: [_order, _stageNarrowed, {carry: Order: stage: values: paid: "gone"}], holds: {refused: [{why: "values carries to what it does not admit: paid → gone"}]}},
		{call: "mig.plan", args: [_order, _stageNarrowed, {carry: Order: stage: set: note: "'x'"}], holds: {refused: [{why: "the carry gives stage no value: name values, or set stage"}]}},
		{call: "mig.plan", args: [_order, _stageNarrowed, {carry: Order: stage: {values: paid: "settled", set: stage: "'new'"}}], holds: {refused: [{why: "both values and set give stage its value"}]}},
		{call: "mig.plan", args: [_order, _stageNarrowed, {carry: Order: stage: set: {stage: "'settled'", status: "'open'"}}], holds: {refused: [{why: "set moves status, which a machine guards: list trg_order_status_machine in triggers"}]}},
		{call: "mig.plan", args: [_order, _stageNarrowed, {carry: Order: stage: {values: paid: "settled", triggers: ["trg_order_step_machine"]}}], holds: {refused: [{why: "triggers names trg_order_step_machine, which is no machine's trigger on order (trg_order_status_machine)"}]}},
	]}
	"a migration relaxes, then moves rows, then tightens, whatever order the columns come in": {suite: "migrations", steps: [
		{call: "mig.plan", args: [_order, [["Order.fields.3.required", true], ["Order.fields.5.enum", ["new", "settled"]], ["Order.fields.6.check", null]], {backfill: Order: note: "''", carry: Order: stage: set: {stage: "'settled'", total: "-1"}}], holds: {ops: [
			{at: "Order.total", why: "its check removed"},
			{at: "Order.note", why: "made required: its NULL rows filled"},
			{at: "Order.stage"},
			{at: "Order.note", why: "made required"},
		]}, why: "the carry writes a total the check it drops would refuse, and the column made required is tightened last"},
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
		]], expect: {idx_order_note: "20261109_0001_a", trg_order_stage_machine: "20261109_0002_b"}, why: "a name the same migration builds again is not dropped"},
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
		{call: "migrations.nextName", args: [[], "a", "20261109", ["20261110_0001_x"]], expect: "20261110_0002_a", why: "a later day already used (a clock ahead) is taken, so the name sorts after it, as pgroll's runner needs"},
		{call: "migrations.nextName", args: [[], "a", "20261109", ["zz_hand"]], throws: "20261109_0001_a sorts before the app's migration zz_hand", why: "no dated name can follow it"},
		{call: "migrations.nextName", args: [[], "Relax-Ref", "20261109"], throws: "lowercase letters, digits and _", why: "pgroll's ledger takes these names"},
		{call: "migrations.nextName", args: [[], "0001", "20261109"], throws: "starting with a letter", why: "the name says what the migration does"},
		{call: "migrations.nextName", args: [[], "a", "2026-11-09"], throws: "YYYYMMDD"},
	]}
	"the ledger embeds each migration into code.state.migrations, and none declares nothing": {suite: "migrations", steps: [
		{call: "migrations.ledger", args: ["shop", ["20261109_0001_a", "20261109_0002_b"]], expect: "// generated by migrations/migrate.ts (make) — do not edit\n@extern(embed)\n\npackage shop\n\n// The app's pgroll migrations (migrations/README.md): each runs once on a database that already\n// holds rows, after the replay of the emitted schema.\ncode: state: migrations: {\n\t\"20261109_0001_a\": _ @embed(file=\"migrations/20261109_0001_a.json\")\n\t\"20261109_0002_b\": _ @embed(file=\"migrations/20261109_0002_b.json\")\n}\n"},
		{call: "migrations.ledger", args: ["shop", []], expect: "// generated by migrations/migrate.ts (make) — do not edit\npackage shop\n", why: "an empty map would still give the cluster a migrate step"},
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
	"the snapshot is the model with its format, keys sorted and field numbers as numbers, and another format is refused": {suite: "migrations", steps: [
		{call: "migrations.snapshot", args: [{b: {fields: {"10": {}, "9": {}}}, a: 1}], expect: "{\n  \"format\": 1,\n  \"model\": {\n    \"a\": 1,\n    \"b\": {\n      \"fields\": {\n        \"9\": {},\n        \"10\": {}\n      }\n    }\n  }\n}\n"},
		{call: "migrations.fromSnapshot", args: ["{\"format\": 1, \"model\": {\"A\": {}}}"], expect: {A: {}}},
		{call: "migrations.fromSnapshot", args: ["{\"format\": 2, \"model\": {}}"], throws: "format 2; this plugin reads format 1"},
	]}
}
