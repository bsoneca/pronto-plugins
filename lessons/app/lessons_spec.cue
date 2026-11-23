package __PACKAGE__

// The courses this app teaches (pronto-lessons: lessons/schema.cue's #Course, in this package beside it).
// Each is `lessons: courses: <id>: {...}`; the plugin emits them to the page (lessons_spec.js), to the database
// (lessons.spec()) and to the message catalogues, by `lessons write` (lessons.nu).
lessons: courses: {}

// The lessons migration's name, among the app's own: pgroll applies them in name order and refuses one named
// before the last it applied, so name it after the app's latest.
_lessonsMigration: "lessons_01"

// The LessonProgress table's identity, which pronto's mint stamps here: the rest of it is pronto-lessons'
// (lessons_plugin.cue).
code: state: entities: {
	LessonProgress: {}
}
