package __PACKAGE__

// The courses this app teaches (pronto-lessons: lessons/schema.cue's #Course, in this package beside it).
// Each is `lessons: courses: <id>: {...}`; the plugin emits them to the page (lessons_spec.js), to the database
// (lessons.spec()) and to the message catalogues, by `lessons write` (lessons.nu).
lessons: courses: {}

// The lessons migration's name, among the app's own: pgroll applies them in name order and refuses one named
// before the last it applied, so name it after the app's latest.
_lessonsMigration: "lessons_01"

// The names of the two raw migrations (lessons_plugin.cue lists them in rawMigrations), stamped by the installer once, after the
// app's own raw migrations, and never changed by it: a rename would leave the old name replayed beside the new.
_lessonsRawNames: {spec: "__RAW_SPEC__", fns: "__RAW_FNS__"}

// The LessonProgress table's identity, which pronto's mint stamps here: the rest of it is pronto-lessons'
// (lessons_plugin.cue).
code: state: entities: {
	LessonProgress: {}
}
