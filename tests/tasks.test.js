'use strict'

// Unit tests for Tasks.js, the pure-JS half of the Google Tasks widget.
//
//   node --test tests/tasks.test.js
//
// Tasks.js carries a `.pragma library` line that QML needs and node's parser
// does not understand, so it is evaluated in a vm context with that line
// stripped rather than required as a module.

const test = require('node:test')
// Loose deepEqual on purpose: objects and arrays returned from the vm context
// have that context's prototypes, which deepStrictEqual would reject.
const assert = require('node:assert')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')

const root = path.join(__dirname, '..')

function loadTasks() {
  const source = fs
    .readFileSync(path.join(root, 'Tasks.js'), 'utf8')
    .replace(/^\.pragma library\s*$/m, '')
  const sandbox = {}
  vm.createContext(sandbox)
  vm.runInContext(
    source +
      '\n;this.T = { pad2, splitNotes, joinNotes, parseClock, normalizeTask,'
      + ' dueMoment, parseTasksResponse, parseTasklists, depthOf, dueKey,'
      + ' buildRows, counts, totals, parseDueIso, keyForDate, monthLabel,'
      + ' monthGrid, dueParts, composeDue, formatDue, isOverdue, isDueToday,'
      + ' TIME_MARK };',
    sandbox
  )
  return sandbox.T
}

const Tasks = loadTasks()
const fixture = (name) => fs.readFileSync(path.join(__dirname, 'fixtures', name), 'utf8')

// ------------------------------------------------------------- task lists ----

test('parseTasklists reads id and title', () => {
  const lists = Tasks.parseTasklists(fixture('tasklists.json'))
  assert.deepEqual(
    lists.map((l) => [l.id, l.title]),
    [['LIST_A', 'My Tasks'], ['LIST_B', 'Work']]
  )
})

test('parseTasklists falls back to a title and drops entries with no id', () => {
  const lists = Tasks.parseTasklists('{"items":[{"id":"x"},{"title":"no id"}]}')
  assert.equal(lists.length, 1)
  assert.equal(lists[0].title, 'Untitled list')
})

test('parseTasklists tolerates junk', () => {
  assert.deepEqual(Tasks.parseTasklists('not json'), [])
  assert.deepEqual(Tasks.parseTasklists(''), [])
})

// ----------------------------------------------------------- task parsing ----

test('parseTasksResponse reads newline-delimited pages and skips garbage', () => {
  const tasks = Tasks.parseTasksResponse(fixture('tasks.ndjson'))
  assert.deepEqual(tasks.map((t) => t.id), ['a', 'b', 'c', 'd'])
})

test('normalizeTask keeps parent, status and the due date prefix', () => {
  const tasks = Tasks.parseTasksResponse(fixture('tasks.ndjson'))
  const byId = Object.fromEntries(tasks.map((t) => [t.id, t]))
  assert.equal(byId.c.status, 'completed')
  assert.equal(byId.b.status, 'needsAction')
  assert.equal(byId.d.parent, 'a')
  assert.equal(Tasks.dueParts(byId.a.due).date, '2026-08-25')
})

test('normalizeTask rejects deleted and id-less entries', () => {
  assert.equal(Tasks.normalizeTask({ id: 'x', deleted: true }), null)
  assert.equal(Tasks.normalizeTask({ title: 'no id' }), null)
  assert.equal(Tasks.normalizeTask(null), null)
})

// -------------------------------------------------------- time in notes ------

test('splitNotes lifts a trailing clock marker out of the notes', () => {
  assert.deepEqual(Tasks.splitNotes('see attached\n\n\u23f0 09:30'), { notes: 'see attached', time: '09:30' })
  assert.deepEqual(Tasks.splitNotes('no time here'), { notes: 'no time here', time: '' })
})

test('an out-of-range clock is left as ordinary text', () => {
  assert.deepEqual(Tasks.splitNotes('x\n\n\u23f0 25:00'), { notes: 'x\n\n\u23f0 25:00', time: '' })
})

test('joinNotes and splitNotes round-trip, with and without notes', () => {
  assert.deepEqual(Tasks.splitNotes(Tasks.joinNotes('body', '09:30')), { notes: 'body', time: '09:30' })
  assert.deepEqual(Tasks.splitNotes(Tasks.joinNotes('', '0930')), { notes: '', time: '09:30' })
  assert.equal(Tasks.joinNotes('body', ''), 'body')
})

test('parseClock normalises the forms a person actually types', () => {
  assert.equal(Tasks.parseClock('09:30'), '09:30')
  assert.equal(Tasks.parseClock('0930'), '09:30')
  assert.equal(Tasks.parseClock('930'), '09:30')
  assert.equal(Tasks.parseClock('9:5'), '09:05')
  assert.equal(Tasks.parseClock('00:00'), '00:00')
  for (const bad of ['2400', '12:60', 'abc', '', '99']) assert.equal(Tasks.parseClock(bad), '')
})

// ------------------------------------------------------------------ dates ----

test('composeDue validates the calendar, not just the shape', () => {
  assert.equal(Tasks.composeDue('2026-02-03'), '2026-02-03T00:00:00.000Z')
  assert.equal(Tasks.composeDue('2026-2-3'), '2026-02-03T00:00:00.000Z')
  assert.equal(Tasks.composeDue('2028-02-29'), '2028-02-29T00:00:00.000Z')
  assert.equal(Tasks.composeDue('2026-02-31'), '')
  assert.equal(Tasks.composeDue('nope'), '')
})

test('dueMoment is local time and needs both a date and a time', () => {
  assert.equal(Tasks.dueMoment({ due: '2026-08-25T00:00:00.000Z', time: '' }), 0)
  const moment = Tasks.dueMoment({ due: '2026-08-25T00:00:00.000Z', time: '09:30' })
  const d = new Date(moment)
  assert.equal(d.getFullYear(), 2026)
  assert.equal(d.getMonth(), 7)
  assert.equal(d.getDate(), 25)
  assert.equal(d.getHours(), 9)
  assert.equal(d.getMinutes(), 30)
})

test('formatDue shows the year only when it is not this year', () => {
  const today = new Date(2026, 8, 19)
  assert.equal(Tasks.formatDue('2026-08-25T00:00:00.000Z', today, ''), 'Aug 25')
  assert.equal(Tasks.formatDue('2026-08-25T00:00:00.000Z', today, '09:30'), 'Aug 25 09:30')
  assert.equal(Tasks.formatDue('2027-01-02T00:00:00.000Z', today, ''), "Jan 2 '27")
  assert.equal(Tasks.formatDue('', today, ''), '')
})

test('overdue and due-today compare calendar days', () => {
  const today = new Date(2026, 8, 19)
  assert.equal(Tasks.isOverdue('2026-09-18T00:00:00.000Z', today), true)
  assert.equal(Tasks.isOverdue('2026-09-19T00:00:00.000Z', today), false)
  assert.equal(Tasks.isDueToday('2026-09-19T00:00:00.000Z', today), true)
  assert.equal(Tasks.isDueToday('2026-09-20T00:00:00.000Z', today), false)
})

// ------------------------------------------------------------------- rows ----

function fixtureTasks() {
  return Tasks.parseTasksResponse(fixture('tasks.ndjson'))
}

test('buildRows orders by position, open before completed', () => {
  const rows = Tasks.buildRows(fixtureTasks(), {})
  assert.deepEqual(rows.map((r) => r.task.id), ['a', 'b', 'd', 'c'])
})

test('buildRows reports subtask depth', () => {
  const rows = Tasks.buildRows(fixtureTasks(), {})
  assert.equal(rows.find((r) => r.task.id === 'd').depth, 1)
  assert.equal(rows.find((r) => r.task.id === 'a').depth, 0)
})

test('buildRows sorts by due date when asked', () => {
  const rows = Tasks.buildRows(fixtureTasks(), { sort: 'due' })
  assert.equal(rows[0].task.id, 'a')
})

test('buildRows hides completed when showCompleted is false', () => {
  const rows = Tasks.buildRows(fixtureTasks(), { showCompleted: false })
  assert.deepEqual(rows.map((r) => r.task.id), ['a', 'b', 'd'])
})

test('buildRows filters on title and notes', () => {
  assert.deepEqual(
    Tasks.buildRows(fixtureTasks(), { filter: 'vendor' }).map((r) => r.task.id),
    ['b']
  )
  assert.deepEqual(
    Tasks.buildRows(fixtureTasks(), { filter: '20k' }).map((r) => r.task.id),
    ['a']
  )
})

test('buildRows survives a parent cycle', () => {
  const cycled = [
    { id: 'x', title: 'X', notes: '', time: '', status: 'needsAction', due: '', position: '1', parent: 'y' },
    { id: 'y', title: 'Y', notes: '', time: '', status: 'needsAction', due: '', position: '2', parent: 'x' }
  ]
  const rows = Tasks.buildRows(cycled, {})
  assert.equal(rows.length, 2)
})

test('counts and totals count open against total', () => {
  const tasks = fixtureTasks()
  assert.deepEqual(Tasks.counts(tasks), { open: 3, total: 4 })
  assert.deepEqual(Tasks.totals({ LIST_A: tasks }), { open: 3, total: 4 })
  assert.deepEqual(Tasks.totals({}), { open: 0, total: 0 })
})

// --------------------------------------------------------------- calendar ----

test('monthGrid is a six-week block that flags the month', () => {
  const cells = Tasks.monthGrid(2026, 7, 1) // August 2026, Monday start
  assert.equal(cells.length, 42)
  assert.equal(cells[0].date, '2026-07-27')
  assert.equal(cells.find((c) => c.date === '2026-08-01').inMonth, true)
  assert.equal(cells.find((c) => c.date === '2026-07-31').inMonth, false)
})

test('keyForDate and parseDueIso agree', () => {
  const d = Tasks.parseDueIso('2026-08-25T00:00:00.000Z')
  assert.equal(Tasks.keyForDate(d), '2026-08-25')
  assert.equal(Tasks.keyForDate(null), '')
})

test('monthLabel names the month', () => {
  assert.equal(Tasks.monthLabel(2026, 7), 'August 2026')
})
