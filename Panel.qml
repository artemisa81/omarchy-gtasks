import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Tasks.js" as Tasks

Panel {
  id: root
  moduleName: "artemisa81.gtasks"
  ipcTarget: "artemisa81.gtasks"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string profileDir: home + "/.config/gws-omarchy-tasks"
  readonly property string cacheDir: home + "/.cache/omarchy-gtasks"

  readonly property int panelWidth: Math.max(300, Number(setting("panelWidth", 460)) || 460)
  readonly property bool showCompletedSetting: setting("showCompleted", true) === true
  readonly property int autoRefreshSec: Math.max(0, Number(setting("autoRefreshSec", 90)) || 0)
  readonly property bool hintsSetting: setting("showHints", true) === true

  readonly property int rowH: Style.spacing.popupRowHeight
  readonly property int maxListH: Style.space(420)

  property var lists: []
  property int listIndex: 0
  property var tasksByList: ({})
  property string filterText: ""
  property int cursor: 0
  property string mode: "normal"
  property string confirmKind: ""
  property bool authNeeded: false
  property bool apiDisabled: false
  property string notice: ""
  property bool noticeIsError: false
  property real lastSyncedAt: 0
  property bool pendingG: false
  // Set as soon as any sync has been kicked off, so the startup sync below
  // stands down if the panel was opened before it got its turn.
  property bool primed: false
  // Guards refreshAll so the auto-refresh timer, a manual `r`, and the startup
  // prime cannot stack three list fetches on top of each other.
  property bool fetchInFlight: false

  property bool calendarOpen: false
  property int calYear: new Date().getFullYear()
  property int calMonth: new Date().getMonth()
  property var calCursor: new Date()
  readonly property int weekStart: 1

  property string editTaskId: ""

  // taskId -> the due moment we have already alerted for, so a restart does not
  // replay old alerts and a rescheduled task alerts again at its new time.
  property var notifiedIds: ({})
  property var alertQueue: []
  property bool alertRunning: false
  // How late an alert may be and still be worth showing. Anything older is a
  // moment the machine was not running for; it is recorded silently rather than
  // dumped on the user as a backlog of toasts at login.
  readonly property int alertGraceMs: 60 * 60 * 1000

  readonly property var currentList: (listIndex >= 0 && listIndex < lists.length) ? lists[listIndex] : null
  readonly property string currentListId: currentList ? currentList.id : ""
  readonly property var currentTasks: (currentListId !== "" && tasksByList[currentListId]) ? tasksByList[currentListId] : []

  readonly property var rows: Tasks.buildRows(currentTasks, {
    showCompleted: showCompletedSetting,
    filter: filterText
  })

  readonly property var counts: Tasks.totals(tasksByList)
  readonly property bool noDataYet: counts.total === 0 && lists.length === 0

  readonly property bool hasSecret: secretFile.loaded === true
  readonly property bool ready: hasSecret && !authNeeded

  readonly property bool editing: mode === "add" || mode === "edit"

  // Said out loud in the editor, because a time that Google will not notify you
  // about is worth being upfront about rather than letting the user find out.
  readonly property string editorHint: dueTimeField && dueTimeField.text !== ""
    ? "Enter save · Tab next · Esc cancel — time is kept in the notes and alerts on this machine only"
    : "Enter save · Tab next · Esc cancel"

  onOpenedChanged: {
    if (!opened) {
      // Reset the transient modes as well as the editor. Leaving help/confirm/
      // calendar/filter set brought the overlay back on the next open, and a
      // filter mode reopened with neither the key handler nor a focused field,
      // so the panel looked dead until something was clicked.
      cancelEditing()
      mode = "normal"
      confirmKind = ""
      calendarOpen = false
      return
    }
    pendingG = false
    if (!hasSecret) return
    if (autoRefreshSec > 0 || lastSyncedAt === 0) refreshAll()
    Qt.callLater(function() { if (mode === "normal") keyItem.forceActiveFocus() })
  }

  // Sync once shortly after login rather than waiting for the first time the
  // panel is opened, so the count in the bar is live from the start instead of
  // showing whatever the cache last held. Delayed a couple of seconds to stay
  // out of the way of the rest of the shell coming up.
  Timer {
    id: primeSyncTimer
    interval: 2500
    repeat: false
    running: root.hasSecret && !root.primed
    onTriggered: root.refreshAll()
  }

  Component.onCompleted: {
    mkdirProc.running = true
  }

  // ------------------------------------------------------------- data io

  function saveCache() {
    cacheFile.setText(JSON.stringify({
      version: 1,
      savedAt: Date.now(),
      lastListId: currentListId,
      lists: lists,
      tasksByList: tasksByList,
      notified: notifiedIds
    }) + "\n")
  }

  function applyCache(raw) {
    var doc = null
    try { doc = JSON.parse(String(raw || "")) } catch (e) { doc = null }
    if (!doc || doc.version !== 1) return
    var ls = Array.isArray(doc.lists) ? doc.lists : []
    var map = (doc.tasksByList && typeof doc.tasksByList === "object") ? doc.tasksByList : {}
    lists = ls
    tasksByList = map
    notifiedIds = (doc.notified && typeof doc.notified === "object") ? doc.notified : ({})
    var wanted = String(doc.lastListId || "")
    for (var i = 0; i < ls.length; i++) {
      if (ls[i].id === wanted) { listIndex = i; break }
    }
    if (listIndex >= ls.length) listIndex = 0
    clampCursor()
  }

  FileView {
    id: cacheFile
    path: root.cacheDir + "/cache.json"
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyCache(text())
    onLoadFailed: root.applyCache("")
  }

  FileView {
    id: secretFile
    path: root.profileDir + "/client_secret.json"
    watchChanges: true
    printErrors: false
  }

  // ------------------------------------------------------------- process queue

  property var opQueue: []
  property bool opRunning: false
  property var currentOp: null
  property string lastOut: ""
  property string lastErr: ""

  readonly property bool busy: opRunning || opQueue.length > 0

  function enqueue(op) {
    if (op.priority) opQueue.unshift(op)
    else opQueue.push(op)
    drainQueue()
  }

  function drainQueue() {
    if (opRunning || opQueue.length === 0) return
    opRunning = true
    currentOp = opQueue.shift()
    lastOut = ""
    lastErr = ""
    apiProc.command = currentOp.argv
    apiProc.running = true
  }

  function finishOp(exitCode) {
    opRunning = false
    var op = currentOp
    currentOp = null
    var out = lastOut
    var err = lastErr

    if (exitCode !== 0) classifyError(err + " " + out, exitCode)
    if (op && typeof op.onDone === "function") {
      try { op.onDone(exitCode, out, err) } catch (e) { console.warn("gtasks:", e) }
    }
    drainQueue()
  }

  function classifyError(text, exitCode) {
    var t = String(text || "")
    if (exitCode === 127 || /\bgws\b[^\n]*(not found|no such file)|command not found/i.test(t)) {
      notice = "gws CLI not found — install it, then retry (see the README)"
      noticeIsError = true
    } else if (/accessNotConfigured|has not been used|is disabled/i.test(t)) {
      apiDisabled = true
      authNeeded = true
      notice = "Google Tasks API not enabled yet"
      noticeIsError = true
    } else if (/insufficient authentication scopes|invalid_grant|unauthorized_client|invalid_client|no credentials|401|403/i.test(t)) {
      authNeeded = true
      apiDisabled = false
      notice = "Google authorization needed"
      noticeIsError = true
    }
  }

  Process {
    id: apiProc
    environment: ({ "GOOGLE_WORKSPACE_CLI_CONFIG_DIR": root.profileDir })
    command: ["true"]
    // waitForEnd makes the collectors finish before onExited runs, so finishOp
    // always sees this process's own output rather than the previous one's.
    stdout: StdioCollector { id: apiStdout; waitForEnd: true }
    stderr: StdioCollector { id: apiStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.lastOut = apiStdout.text
      root.lastErr = apiStderr.text
      root.finishOp(exitCode)
    }
  }

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.cacheDir]
  }

  // ------------------------------------------------------------- fetching

  function fetchLists() {
    fetchInFlight = true
    enqueue({
      argv: ["gws", "tasks", "tasklists", "list"],
      onDone: function(code, out, err) {
        fetchInFlight = false
        if (code !== 0) {
          if (!authNeeded) { notice = "Could not load task lists"; noticeIsError = true }
          return
        }
        if (authNeeded) {
          authNeeded = false
          apiDisabled = false
          notice = ""
        }
        var ls = Tasks.parseTasklists(out)
        lastSyncedAt = Date.now()
        var wanted = currentListId
        lists = ls
        // Drop tasks for lists that no longer exist. Without this a list
        // deleted in Google stays in the model forever: the bar keeps counting
        // its tasks and alerts keep firing for them.
        var keep = {}
        for (var k = 0; k < ls.length; k++) keep[ls[k].id] = true
        var pruned = {}
        for (var oldId in tasksByList) if (keep[oldId]) pruned[oldId] = tasksByList[oldId]
        tasksByList = pruned
        var found = false
        for (var i = 0; i < ls.length; i++) {
          if (ls[i].id === wanted) { listIndex = i; found = true; break }
        }
        if (!found) listIndex = 0
        clampCursor()
        saveCache()
        for (var j = 0; j < ls.length; j++) {
          enqueueFetch(ls[j].id, ls[j].id === currentListId)
        }
      }
    })
  }

  function enqueueFetch(listId, priority) {
    enqueue({
      priority: priority === true,
      argv: ["gws", "tasks", "tasks", "list",
        "--params", JSON.stringify({
          tasklist: listId,
          showCompleted: true,
          showHidden: false,
          maxResults: 100
        }),
        "--page-all", "--page-limit", "3"],
      onDone: function(code, out, err) {
        if (code !== 0) return
        var next = {}
        for (var key in tasksByList) next[key] = tasksByList[key]
        next[listId] = Tasks.parseTasksResponse(out)
        tasksByList = next
        lastSyncedAt = Date.now()
        clampCursor()
        saveCache()
      }
    })
  }

  function refreshAll() {
    if (!hasSecret) return
    if (fetchInFlight) return
    primed = true
    notice = ""
    fetchLists()
  }

  Timer {
    interval: Math.max(15, root.autoRefreshSec) * 1000
    running: root.opened && root.autoRefreshSec > 0 && root.hasSecret
    repeat: true
    onTriggered: root.refreshAll()
  }

  // ------------------------------------------------------------- local mutations

  function setListTasks(listId, arr) {
    var next = {}
    for (var k in tasksByList) next[k] = tasksByList[k]
    next[listId] = arr
    tasksByList = next
    saveCache()
  }

  function findTask(taskId) {
    var arr = currentTasks
    for (var i = 0; i < arr.length; i++) {
      if (arr[i].id === taskId) return { task: arr[i], index: i }
    }
    return null
  }

  function replaceTaskLocal(taskId, nextTask) {
    var hit = findTask(taskId)
    if (!hit) return
    var copy = currentTasks.slice()
    copy[hit.index] = nextTask
    setListTasks(currentListId, copy)
  }

  function removeTaskLocal(taskId) {
    var hit = findTask(taskId)
    if (!hit) return false
    var copy = currentTasks.slice()
    copy.splice(hit.index, 1)
    setListTasks(currentListId, copy)
    return true
  }

  // ------------------------------------------------------------- remote mutations

  // Patch, never update. `tasks.update` is a PUT: it replaces the task with
  // exactly the body sent, so any field left out is cleared. That matters more
  // than it looks, because a Google task carries state this API cannot see —
  // above all the time of day behind a due date set in the web UI or on a
  // phone, which is what makes Google notify you. Ticking a task off with a PUT
  // takes that time down with it. Patching only the fields actually edited
  // leaves everything else, visible or not, untouched.
  function enqueuePatch(taskId, body, listId) {
    enqueue({
      priority: true,
      argv: ["gws", "tasks", "tasks", "patch",
        "--params", JSON.stringify({ tasklist: listId, task: taskId }),
        "--json", JSON.stringify(body)],
      onDone: function(code, out, err) {
        if (code !== 0) {
          notice = "Update failed — reloading"
          noticeIsError = true
          enqueueFetch(listId, true)
          return
        }
        var updated = null
        try { updated = Tasks.normalizeTask(JSON.parse(out)) } catch (e) { updated = null }
        if (updated) replaceTaskLocal(updated.id, updated)
      }
    })
  }

  // Removing a due date is the one edit patch cannot express — `due: null` is
  // accepted and then ignored — so it takes the PUT path, sending the whole
  // task without a date. Dropping whatever time was attached to it is exactly
  // what the user asked for here, so the caveat above does not apply.
  function enqueueClearDue(task, listId) {
    var body = {
      id: task.id,
      title: task.title,
      notes: Tasks.joinNotes(task.notes, task.time),
      status: task.status
    }
    if (task.parent) body.parent = task.parent
    enqueue({
      priority: true,
      argv: ["gws", "tasks", "tasks", "update",
        "--params", JSON.stringify({ tasklist: listId, task: task.id }),
        "--json", JSON.stringify(body)],
      onDone: function(code, out, err) {
        if (code !== 0) {
          notice = "Update failed — reloading"
          noticeIsError = true
          enqueueFetch(listId, true)
          return
        }
        var updated = null
        try { updated = Tasks.normalizeTask(JSON.parse(out)) } catch (e) { updated = null }
        if (updated) replaceTaskLocal(updated.id, updated)
      }
    })
  }

  function toggleDone(index) {
    var row = rows[index]
    if (!row || !ready) return
    var t = row.task
    var nextStatus = t.status === "completed" ? "needsAction" : "completed"
    replaceTaskLocal(t.id, Object.assign({}, t, { status: nextStatus }))
    enqueuePatch(t.id, { status: nextStatus }, currentListId)
  }

  function commitAdd(title, notes, due, time) {
    if (!ready || title === "") return
    var listId = currentListId
    // A time with no date has no moment to arrive, so it is dropped rather than
    // stored where nothing would ever read it.
    var wireNotes = Tasks.joinNotes(notes, due !== "" ? time : "")
    var body = { title: title }
    if (wireNotes !== "") body.notes = wireNotes
    if (due !== "") body.due = due
    enqueue({
      priority: true,
      argv: ["gws", "tasks", "tasks", "insert",
        "--params", JSON.stringify({ tasklist: listId }),
        "--json", JSON.stringify(body)],
      onDone: function(code, out, err) {
        if (code !== 0) {
          notice = "Could not add task"
          noticeIsError = true
          return
        }
        notice = "Task added"
        noticeIsError = false
        enqueueFetch(listId, false)
      }
    })
  }

  function commitEdit(taskId, title, notes, due, time) {
    var hit = findTask(taskId)
    if (!hit || !ready) return
    var before = hit.task
    var keptTime = due !== "" ? time : ""
    var edited = Object.assign({}, before, {
      title: title, notes: notes, due: due, time: keptTime
    })
    replaceTaskLocal(taskId, edited)

    var listId = currentListId
    var wireNotes = Tasks.joinNotes(notes, keptTime)
    var wireBefore = Tasks.joinNotes(before.notes, before.time)

    // A cleared date has to go through the PUT path, and that body carries the
    // edited title and notes with it, so there is nothing left to patch.
    if (due === "" && before.due !== "") {
      enqueueClearDue(edited, listId)
      return
    }

    var body = {}
    if (title !== before.title) body.title = title
    if (wireNotes !== wireBefore) body.notes = wireNotes
    if (due !== before.due) body.due = due
    for (var _k in body) { enqueuePatch(taskId, body, listId); return }
  }

  function requestDelete() {
    var row = rows[cursor]
    if (!row || !ready) return
    confirmKind = "delete"
    mode = "confirm"
  }

  function requestClearCompleted() {
    if (!ready) return
    var c = Tasks.counts(currentTasks)
    if (c.total - c.open === 0) {
      notice = "No completed tasks to clear"
      noticeIsError = false
      return
    }
    confirmKind = "clearCompleted"
    mode = "confirm"
  }

  function confirmAction() {
    var kind = confirmKind
    confirmKind = ""
    mode = "normal"
    keyItem.forceActiveFocus()

    if (kind === "delete") {
      var row = rows[cursor]
      if (!row) return
      var taskId = row.task.id
      var listId = currentListId
      removeTaskLocal(taskId)
      enqueue({
        priority: true,
        argv: ["gws", "tasks", "tasks", "delete",
          "--params", JSON.stringify({ tasklist: listId, task: taskId })],
        onDone: function(code, out, err) {
          if (code !== 0) {
            notice = "Delete failed"
            noticeIsError = true
            enqueueFetch(listId, true)
          }
        }
      })
    } else if (kind === "clearCompleted") {
      var lid = currentListId
      enqueue({
        priority: true,
        argv: ["gws", "tasks", "tasks", "clear",
          "--params", JSON.stringify({ tasklist: lid })],
        onDone: function(code, out, err) {
          if (code !== 0) {
            notice = "Clear failed"
            noticeIsError = true
          }
          enqueueFetch(lid, false)
        }
      })
    }
  }

  function cancelConfirm() {
    confirmKind = ""
    mode = "normal"
    keyItem.forceActiveFocus()
  }

  // Row indices of everything that reorders alongside `row`: same parent, same
  // depth, and the same completed/open block, since the two blocks are sorted
  // against each other rather than by position.
  function siblingRowsOf(row) {
    var out = []
    for (var i = 0; i < rows.length; i++) {
      var candidate = rows[i]
      if (candidate.depth !== row.depth) continue
      if (candidate.task.parent !== row.task.parent) continue
      if (candidate.task.status !== row.task.status) continue
      out.push(i)
    }
    return out
  }

  function moveTask(delta) {
    var row = rows[cursor]
    if (!row || !ready) return

    var siblings = siblingRowsOf(row)
    var at = siblings.indexOf(cursor)
    if (at === -1) return
    var to = at + (delta < 0 ? -1 : 1)
    if (to < 0 || to >= siblings.length) return

    var params = { tasklist: currentListId, task: row.task.id }
    if (row.task.parent) params.parent = row.task.parent

    // `previous` names the sibling the task should land *after*; omitting it
    // moves the task to the front. Landing after `to` moves it down one place;
    // landing after the sibling before `to` moves it up one place.
    var previousAt = delta < 0 ? to - 1 : to
    if (previousAt >= 0) params.previous = rows[siblings[previousAt]].task.id

    // Follow the task rather than the slot, so a held J walks it down the list
    // instead of dragging whatever swapped into place.
    cursor = siblings[to]

    var listId = currentListId
    enqueue({
      priority: true,
      argv: ["gws", "tasks", "tasks", "move", "--params", JSON.stringify(params)],
      onDone: function(code, out, err) {
        if (code !== 0) {
          notice = "Reorder failed"
          noticeIsError = true
        }
        enqueueFetch(listId, code !== 0)
      }
    })
  }

  // ------------------------------------------------------------- alerts

  // Google never receives the time, so it cannot notify for it. This does.
  // Every timed, still-open task gets exactly one desktop notification when its
  // moment arrives; `notifiedIds` rides along in the cache so a shell restart
  // does not replay them.
  // Key-order-independent comparison so a rebuilt object with identical
  // contents does not trigger a cache write every 30 seconds.
  function sameNotified(a, b) {
    var ka = Object.keys(a), kb = Object.keys(b)
    if (ka.length !== kb.length) return false
    for (var i = 0; i < ka.length; i++) if (b[ka[i]] !== a[ka[i]]) return false
    return true
  }

  function checkAlerts() {
    // Before the cache has been applied there is nothing to check, and saving
    // from here would overwrite the cache with an empty model.
    if (lists.length === 0) return

    var now = Date.now()
    var next = ({})
    var fire = []

    for (var listId in tasksByList) {
      var arr = tasksByList[listId] || []
      for (var i = 0; i < arr.length; i++) {
        var task = arr[i]
        var moment = Tasks.dueMoment(task)
        if (moment === 0) continue
        var already = notifiedIds[task.id]

        // Keep a completed task's record so that reopening it does not replay
        // an alert it already delivered.
        if (task.status === "completed") {
          if (already !== undefined) next[task.id] = already
          continue
        }
        // Still in the future: drop any stale record, so a task moved to a
        // later time alerts again when it gets there.
        if (moment > now) continue
        if (already === moment) { next[task.id] = already; continue }

        if (now - moment <= alertGraceMs) fire.push(task)
        next[task.id] = moment
      }
    }

    // Rebuilt from the live tasks each pass, so records for deleted tasks and
    // for times that have been removed fall out on their own.
    if (!sameNotified(next, notifiedIds)) {
      notifiedIds = next
      saveCache()
    }
    for (var f = 0; f < fire.length; f++) queueAlert(fire[f])
  }

  function queueAlert(task) {
    var q = alertQueue.slice()
    q.push({ title: task.title, time: task.time })
    alertQueue = q
    drainAlerts()
  }

  function drainAlerts() {
    if (alertRunning || alertQueue.length === 0) return
    var alert = alertQueue[0]
    alertQueue = alertQueue.slice(1)
    alertRunning = true
    alertProc.command = ["omarchy-notification-send",
      "--app-name", "Google Tasks",
      "-u", "normal",
      "-g", "\uf0ae",
      "--exec", "omarchy-shell artemisa81.gtasks open",
      "Task due" + (alert.time ? " \u00b7 " + alert.time : ""),
      alert.title]
    alertProc.running = true
  }

  Process {
    id: alertProc
    command: ["true"]
    onExited: {
      root.alertRunning = false
      root.drainAlerts()
    }
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.checkAlerts()
  }

  // ------------------------------------------------------------- navigation

  function clampCursor() {
    var max = Math.max(0, rows.length - 1)
    if (cursor > max) cursor = max
    if (cursor < 0) cursor = 0
    if (listView) listView.positionViewAtIndex(cursor, ListView.Contain)
  }

  function moveCursor(d) {
    var next = cursor + d
    if (next < 0) next = 0
    if (next > rows.length - 1) next = rows.length - 1
    cursor = next
    if (listView) listView.positionViewAtIndex(cursor, ListView.Contain)
  }

  function switchList(d) {
    if (lists.length === 0) return
    listIndex = (listIndex + d + lists.length) % lists.length
    cursor = 0
    saveCache()
    if ((tasksByList[currentListId] || []).length === 0) enqueueFetch(currentListId, true)
  }

  // ------------------------------------------------------------- modes

  function startAdd() {
    if (!ready) return
    editTaskId = ""
    titleField.text = ""
    notesField.text = ""
    dueDateField.text = ""
    dueTimeField.text = ""
    mode = "add"
    Qt.callLater(function() { titleField.forceActiveFocus() })
  }

  function startEdit() {
    var row = rows[cursor]
    if (!row || !ready) return
    editTaskId = row.task.id
    titleField.text = row.task.title
    notesField.text = row.task.notes
    dueDateField.text = Tasks.dueParts(row.task.due).date
    dueTimeField.text = row.task.time || ""
    mode = "edit"
    Qt.callLater(function() { titleField.forceActiveFocus() })
  }

  function cancelEditing() {
    if (!editing) return
    editTaskId = ""
    titleField.text = ""
    notesField.text = ""
    dueDateField.text = ""
    dueTimeField.text = ""
    mode = "normal"
    keyItem.forceActiveFocus()
  }

  function commitEditing() {
    var title = titleField.text.replace(/^\s+|\s+$/g, "")
    var notes = notesField.text
    var due = Tasks.composeDue(dueDateField.text)
    var time = Tasks.parseClock(dueTimeField.text)
    if (title === "") { cancelEditing(); return }
    if (mode === "add") commitAdd(title, notes, due, time)
    else if (mode === "edit" && editTaskId !== "") commitEdit(editTaskId, title, notes, due, time)
    cancelEditing()
  }

  function startFilter() {
    mode = "filter"
    Qt.callLater(function() {
      filterField.forceActiveFocus()
      filterField.selectAll()
    })
  }

  function openHelp() {
    mode = "help"
  }

  function closeHelp() {
    mode = "normal"
    keyItem.forceActiveFocus()
  }

  function openCalendar() {
    if (!editing) return
    var m = dueDateField.text.match(/^(\d{4})-(\d{1,2})-(\d{1,2})$/)
    var base = m ? new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3])) : new Date()
    calCursor = new Date(base.getFullYear(), base.getMonth(), base.getDate())
    calYear = calCursor.getFullYear()
    calMonth = calCursor.getMonth()
    calendarOpen = true
    keyItem.forceActiveFocus()
  }

  function closeCalendar() {
    calendarOpen = false
    if (editing) Qt.callLater(function() { dueDateField.forceActiveFocus() })
    else keyItem.forceActiveFocus()
  }

  function pickCalendarDate() {
    if (!calendarOpen) return
    dueDateField.text = Tasks.keyForDate(calCursor)
    closeCalendar()
  }

  function calStep(dx, dy) {
    var d = new Date(calCursor.getFullYear(), calCursor.getMonth(),
      calCursor.getDate() + dx + dy * 7)
    calCursor = d
    calYear = d.getFullYear()
    calMonth = d.getMonth()
  }

  // `omarchy-shell artemisa81.gtasks state` writes this next to the cache, so a
  // panel that misbehaves can be inspected without a debugger attached.
  function debugDump() {
    stateFile.setText(JSON.stringify({
      opened: opened === true,
      panelVisible: card ? card.visible === true : null,
      keyboardFocus: keyItem ? keyItem.activeFocus === true : null,
      mode: mode,
      notice: notice,
      noticeIsError: noticeIsError,
      authNeeded: authNeeded,
      apiDisabled: apiDisabled,
      hasSecret: hasSecret,
      busy: busy,
      queued: opQueue.length,
      lists: lists.length,
      listIndex: listIndex,
      currentListId: currentListId,
      visibleRows: rows.length,
      filter: filterText,
      editing: editing,
      calendarOpen: calendarOpen,
      lastSyncedAt: lastSyncedAt
    }, null, 1) + "\n")
  }

  FileView {
    id: stateFile
    path: root.cacheDir + "/state.json"
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  function stopFilter() {
    mode = "normal"
    keyItem.forceActiveFocus()
  }

  function clearFilter() {
    filterText = ""
    filterField.text = ""
    cursor = 0
  }

  function launchSetup() {
    var scriptPath = decodeURIComponent(Qt.resolvedUrl("setup.sh").toString().replace(/^file:\/\//, ""))
    // An argv vector, not a shell string: a HOME containing a space or a quote
    // would otherwise break the command or inject into it.
    Util.execArgv(["omarchy-launch-tui", "--app-id=org.omarchy.gtasks-setup", "bash", scriptPath])
  }

  // ------------------------------------------------------------- popup surface

  // A layer-shell KeyboardPanel, not a PopupCard. PopupCard is an xdg-popup,
  // and an xdg-popup only receives keys once a click routes focus through its
  // parent surface: summoned from IPC or a keybind it opened without focus and
  // its focus grab cleared on the spot, closing it again in the same frame.
  // KeyboardPanel primes layer-shell keyboard focus on every open, which is
  // what a panel driven entirely from the keyboard needs.
  KeyboardPanel {
    id: card
    anchorItem: root.anchorItem
    bar: root.bar
    owner: root.barIdentity
    open: root.opened
    focusTarget: keyItem
    contentWidth: card.fittedContentWidth(root.panelWidth)
    // Measured off the column rather than re-added row by row here: the hand
    // summed version drifted out of step with the layout and had to be
    // corrected every time a row was added or removed.
    //
    // fittedContentHeight, not cappedContentHeight: capped takes the height of
    // the whole card, fitted takes the height of the content and adds the
    // card's padding and borders itself. Passing content height to the capped
    // one left the card short by exactly the padding, which is why the footer
    // line rendered outside it.
    contentHeight: card.fittedContentHeight(Math.max(Style.space(320), innerCol.implicitHeight))

    Item {
      id: keyItem
      anchors.fill: parent
      focus: true
      Keys.enabled: root.calendarOpen || root.mode === "normal" || root.mode === "confirm" || root.mode === "help"
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (root.calendarOpen) {
          if (event.key === Qt.Key_Escape) { root.closeCalendar(); event.accepted = true }
          else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            root.pickCalendarDate(); event.accepted = true
          }
          else if (event.key === Qt.Key_Left || event.text === "h") { root.calStep(-1, 0); event.accepted = true }
          else if (event.key === Qt.Key_Right || event.text === "l") { root.calStep(1, 0); event.accepted = true }
          else if (event.key === Qt.Key_Up || event.text === "k") { root.calStep(0, -1); event.accepted = true }
          else if (event.key === Qt.Key_Down || event.text === "j") { root.calStep(0, 1); event.accepted = true }
          return
        }

        if (root.mode === "help") {
          root.closeHelp()
          event.accepted = true
          return
        }

        if (root.mode === "confirm") {
          // Delegate to the first-party dialog so arrows/Tab move the selection
          // and Enter acts on whichever button is highlighted.
          if (confirmDialog.handleKey(event)) event.accepted = true
          return
        }

        if (event.key === Qt.Key_Escape || event.text === "q") { root.close(); event.accepted = true; return }
        if (event.key === Qt.Key_Down || event.text === "j") { root.moveCursor(1); event.accepted = true; return }
        if (event.key === Qt.Key_Up || event.text === "k") { root.moveCursor(-1); event.accepted = true; return }
        if (event.key === Qt.Key_Left || event.text === "h") { root.switchList(-1); event.accepted = true; return }
        if (event.key === Qt.Key_Right || event.text === "l") { root.switchList(1); event.accepted = true; return }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
          root.toggleDone(root.cursor); event.accepted = true; return
        }
        if (event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace || event.text === "d" || event.text === "x") {
          root.requestDelete(); event.accepted = true; return
        }
        if (event.text === "a") { root.startAdd(); event.accepted = true; return }
        if (event.text === "e") { root.startEdit(); event.accepted = true; return }
        if (event.key === Qt.Key_J) { root.moveTask(1); event.accepted = true; return }
        if (event.key === Qt.Key_K) { root.moveTask(-1); event.accepted = true; return }
        if (event.text === "/") { root.startFilter(); event.accepted = true; return }
        if (event.text === "r") { root.refreshAll(); event.accepted = true; return }
        if (event.text === "c") { root.requestClearCompleted(); event.accepted = true; return }
        if (event.text === "?") {
          if (root.mode === "help") root.closeHelp()
          else root.openHelp()
          event.accepted = true; return
        }
        if (event.text === "g") {
          if (root.pendingG) { root.moveCursor(-root.rows.length); root.pendingG = false }
          else { root.pendingG = true; gResetTimer.restart() }
          event.accepted = true; return
        }
        if (event.text === "G") { root.moveCursor(root.rows.length); event.accepted = true; return }
      }

      Timer {
        id: gResetTimer
        interval: 700
        onTriggered: root.pendingG = false
      }

      Column {
        id: innerCol
        anchors.fill: parent
        spacing: Style.spacing.sm

        Item {
          id: headerBar
          width: parent.width
          implicitHeight: Style.spacing.controlHeight

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.sm

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "\uf0ae"
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.iconLarge
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Tasks"
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.weight: Font.DemiBold
            }
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xs

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(22)
              height: Style.spacing.controlHeight - Style.spacing.sm
              radius: Style.cornerRadius / 2
              color: maPrev.containsMouse ? Style.hoverFill : "transparent"
              Text {
                anchors.centerIn: parent
                text: "\uf104"
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              MouseArea {
                id: maPrev
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.switchList(-1)
              }
            }

            Item {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(120)
              height: Style.spacing.controlHeight - Style.spacing.sm
              Text {
                anchors.centerIn: parent
                width: parent.width
                text: root.currentList ? root.currentList.title : (root.lists.length === 0 ? "no lists" : "")
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideMiddle
                horizontalAlignment: Text.AlignHCenter
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.switchList(1)
              }
            }

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(22)
              height: Style.spacing.controlHeight - Style.spacing.sm
              radius: Style.cornerRadius / 2
              color: maNext.containsMouse ? Style.hoverFill : "transparent"
              Text {
                anchors.centerIn: parent
                text: "\uf105"
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              MouseArea {
                id: maNext
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.switchList(1)
              }
            }

            Item {
              id: busySpin
              visible: root.busy
              width: Style.font.icon
              height: Style.font.icon
              anchors.verticalCenter: parent.verticalCenter
              Text {
                anchors.centerIn: parent
                text: "\uf021"
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.icon
              }
              RotationAnimation on rotation {
                running: root.busy
                loops: Animation.Infinite
                from: 0
                to: 360
                duration: 1100
              }
            }

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(22)
              height: Style.spacing.controlHeight - Style.spacing.sm
              radius: Style.cornerRadius / 2
              color: maClose.containsMouse ? Style.hoverFill : "transparent"
              Text {
                anchors.centerIn: parent
                text: "\uf00d"
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              MouseArea {
                id: maClose
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.close()
              }
            }
          }
        }

        Row {
          id: filterRow
          visible: root.mode === "filter" || root.filterText !== ""
          width: parent.width
          spacing: Style.spacing.xs

          TextField {
            id: filterField
            width: parent.width - clearFilterBtn.width - Style.spacing.xs
            verticalPadding: Style.spacing.xs
            placeholderText: "filter tasks…"
            text: root.filterText
            font.pixelSize: Style.font.bodySmall
            onTextChanged: {
              if (root.mode === "filter" && text !== root.filterText) {
                root.filterText = text
                root.cursor = 0
              }
            }
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.stopFilter()
                event.accepted = true
              } else if (event.key === Qt.Key_Escape) {
                // Esc clears the filter and leaves filter mode; Enter keeps the
                // filter and just returns focus to the list.
                root.clearFilter()
                root.stopFilter()
                event.accepted = true
              }
            }
          }

          Rectangle {
            id: clearFilterBtn
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(22)
            height: Style.space(22)
            radius: Style.cornerRadius / 2
            visible: root.filterText !== ""
            color: maClear.containsMouse ? Style.hoverFill : "transparent"
            Text {
              anchors.centerIn: parent
              text: "\uf00d"
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            MouseArea {
              id: maClear
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: { root.clearFilter(); root.stopFilter() }
            }
          }
        }

        Rectangle {
          id: addRow
          visible: root.ready && !root.editing
          width: parent.width
          implicitHeight: Style.space(24)
          radius: Style.cornerRadius / 3
          color: maAdd.containsMouse || maAdd.pressed ? Style.hoverFill : Style.normalFill
          border.width: Style.normalBorderWidth
          border.color: Style.normalBorderColor

          Row {
            anchors.centerIn: parent
            spacing: Style.spacing.sm

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "\uf0fe"
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Add task"
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }

          MouseArea {
            id: maAdd
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.startAdd()
          }
        }

        Item {
          id: listArea
          width: parent.width
          height: Math.max(Style.space(200), Math.min(root.rows.length * root.rowH + Style.space(8), root.maxListH))

          ListView {
            id: listView
            anchors.fill: parent
            clip: true
            model: root.rows
            currentIndex: root.cursor
            spacing: 0
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
              width: listView.width
              height: root.rowH
              radius: Style.cornerRadius / 3
              color: model.index === root.cursor
                ? Style.selectedFill
                : (maRow.containsMouse ? Style.hoverFill : "transparent")

              readonly property var taskData: modelData.task
              readonly property bool isDone: taskData.status === "completed"
              readonly property bool overdue: !isDone && Tasks.isOverdue(taskData.due, new Date())
              readonly property bool dueToday: !isDone && Tasks.isDueToday(taskData.due, new Date())

              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.spacing.rowPaddingX + modelData.depth * Style.space(12)
                anchors.rightMargin: Style.spacing.rowPaddingX
                spacing: Style.spacing.sm

                Item {
                  id: checkboxSlot
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.font.iconSmall + Style.space(4)
                  height: Style.font.iconSmall + Style.space(4)
                  Text {
                    anchors.centerIn: parent
                    text: isDone ? "\uf046" : "\uf096"
                    color: isDone ? Color.muted : (overdue ? Color.urgent : Color.accent)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.iconSmall
                  }
                  MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Style.space(4)
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.cursor = model.index
                      root.toggleDone(model.index)
                    }
                  }
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width
                    - (Style.spacing.rowPaddingX + modelData.depth * Style.space(12))
                    - Style.spacing.rowPaddingX
                    - checkboxSlot.width
                    - parent.spacing
                    - (hasNotesGlyph.visible ? hasNotesGlyph.width + parent.spacing : 0)
                    - (dueBadge.visible ? dueBadge.width + parent.spacing : 0)
                  text: taskData.title === "" ? "(untitled)" : taskData.title
                  color: isDone ? Qt.alpha(Color.foreground, 0.45) : (model.index === root.cursor ? Color.popups.text : Color.foreground)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.strikeout: isDone
                  elide: Text.ElideRight
                }

                Text {
                  id: hasNotesGlyph
                  anchors.verticalCenter: parent.verticalCenter
                  visible: taskData.notes !== ""
                  text: "\uf036"
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Item {
                  id: dueBadge
                  anchors.verticalCenter: parent.verticalCenter
                  width: dueText.text !== "" ? dueText.implicitWidth + Style.space(10) : 0
                  height: root.rowH - Style.space(8)
                  visible: dueText.text !== "" && !isDone
                  Rectangle {
                    anchors.fill: parent
                    radius: height / 2
                    color: overdue ? Qt.alpha(Color.urgent, 0.16)
                      : (dueToday ? Qt.alpha(Color.accent, 0.14) : "transparent")
                  }
                  Text {
                    id: dueText
                    anchors.centerIn: parent
                    text: Tasks.formatDue(taskData.due, new Date(), taskData.time)
                    color: overdue ? Color.urgent : (dueToday ? Color.accent : Color.muted)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.cursor = model.index
                      root.startEdit()
                      Qt.callLater(root.openCalendar)
                    }
                  }
                }
              }

              MouseArea {
                id: maRow
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPressed: function(mouse) {
                  root.cursor = model.index
                  if (mouse.modifiers & Qt.ControlModifier) root.startEdit()
                }
                onDoubleClicked: root.startEdit()
              }
            }
          }

          Column {
            anchors.centerIn: parent
            visible: root.rows.length === 0
            spacing: Style.spacing.md

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.filterText !== "" ? "no tasks match “" + root.filterText + "”" : "no tasks here"
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              visible: root.filterText === "" && root.ready
              text: "press  a  — or click Add task above"
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        Rectangle {
          id: editorSheet
          visible: root.editing
          width: parent.width
          implicitHeight: editorColumn.implicitHeight + Style.space(14)
          radius: Style.cornerRadius / 2
          color: Style.normalFill
          border.width: Style.normalBorderWidth
          border.color: Style.normalBorderColor

          Column {
            id: editorColumn
            anchors.fill: parent
            anchors.margins: Style.space(7)
            spacing: Style.spacing.xs

            Text {
              text: root.mode === "add" ? "new task" : "edit task"
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            TextField {
              id: titleField
              width: parent.width
              verticalPadding: Style.spacing.xs
              placeholderText: "title"
              font.pixelSize: Style.font.body
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) { root.cancelEditing(); event.accepted = true }
                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  if (root.mode === "add" && notesField.text === "" && dueDateField.text === "" && dueTimeField.text === "")
                    root.commitEditing()
                  else notesField.forceActiveFocus()
                  event.accepted = true
                }
                else if (event.key === Qt.Key_Tab) { notesField.forceActiveFocus(); event.accepted = true }
              }
            }

            TextField {
              id: notesField
              width: parent.width
              verticalPadding: Style.spacing.xs
              placeholderText: "notes (optional)"
              font.pixelSize: Style.font.bodySmall
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) { root.cancelEditing(); event.accepted = true }
                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.commitEditing(); event.accepted = true }
                else if (event.key === Qt.Key_Tab) { dueDateField.forceActiveFocus(); event.accepted = true }
                else if (event.key === Qt.Key_Backtab) { titleField.forceActiveFocus(); event.accepted = true }
              }
            }

            // The date goes to Google as a date; the time of day rides along
            // in the notes, because the API has nowhere else to put it. See
            // the codec at the top of Tasks.js.
            Row {
              width: parent.width
              spacing: Style.spacing.sm

              TextField {
                id: dueDateField
                width: (parent.width - parent.spacing * 2 - calBtn.width) * 0.58
                verticalPadding: Style.spacing.xs
                placeholderText: "due date  ↓ calendar"
                font.pixelSize: Style.font.bodySmall
                // Not ImhDigitsOnly: the field wants YYYY-MM-DD, and a digits
                // hint makes virtual keyboards refuse the dashes.
                inputMethodHints: Qt.ImhNone
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) { root.cancelEditing(); event.accepted = true }
                  else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.commitEditing(); event.accepted = true }
                  else if (event.key === Qt.Key_Tab) { dueTimeField.forceActiveFocus(); event.accepted = true }
                  else if (event.key === Qt.Key_Backtab) { notesField.forceActiveFocus(); event.accepted = true }
                  else if (event.key === Qt.Key_Down) { root.openCalendar(); event.accepted = true }
                }
              }

              Rectangle {
                id: calBtn
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(26)
                height: Style.spacing.controlHeight
                radius: Style.cornerRadius / 2
                color: maCal.containsMouse ? Style.hoverFill : Style.normalFill
                border.width: Style.normalBorderWidth
                border.color: Style.normalBorderColor
                Text {
                  anchors.centerIn: parent
                  text: "\uf133"
                  color: Color.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
                MouseArea {
                  id: maCal
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openCalendar()
                }
              }

              TextField {
                id: dueTimeField
                width: (parent.width - parent.spacing * 2 - calBtn.width) * 0.42
                verticalPadding: Style.spacing.xs
                placeholderText: "time  eg 0930"
                font.pixelSize: Style.font.bodySmall
                inputMethodHints: Qt.ImhDigitsOnly
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) { root.cancelEditing(); event.accepted = true }
                  else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.commitEditing(); event.accepted = true }
                  else if (event.key === Qt.Key_Tab) { titleField.forceActiveFocus(); event.accepted = true }
                  else if (event.key === Qt.Key_Backtab) { dueDateField.forceActiveFocus(); event.accepted = true }
                }
              }
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: root.editorHint
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        Item {
          id: footerBar
          width: parent.width
          implicitHeight: statusText.implicitHeight

          Text {
            id: hintText
            anchors.left: parent.left
            anchors.right: statusText.left
            anchors.rightMargin: Style.spacing.lg
            anchors.verticalCenter: parent.verticalCenter
            visible: root.hintsSetting && root.mode !== "confirm" && !root.editing
            text: "↵ done · a add · e edit · d del · / filter · ? all keys"
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            id: statusText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: {
              if (root.notice !== "") return root.notice
              if (!root.hasSecret) return "not signed in"
              if (root.busy) return "syncing…"
              if (root.lastSyncedAt > 0) return "synced " + Qt.formatTime(new Date(root.lastSyncedAt), "HH:mm")
              return ""
            }
            color: root.noticeIsError ? Color.urgent : Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      Rectangle {
        id: signInOverlay
        anchors.fill: parent
        visible: root.authNeeded || (!root.hasSecret && root.noDataYet)
        color: Qt.alpha(Color.background, 0.93)
        radius: Style.cornerRadius

        Column {
          anchors.centerIn: parent
          spacing: Style.spacing.lg
          width: Math.min(parent.width - Style.space(32), Style.space(280))

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "\uf0ae"
            color: Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.displayLarge
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: root.apiDisabled
              ? "The Google Tasks API is not enabled\nfor your GCP project yet.\nEnable it, then retry."
              : "Connect your Google account\nto load your task lists."
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Style.space(180)
            height: Style.spacing.controlHeight
            radius: Style.cornerRadius / 2
            color: maSignIn.containsMouse ? Style.pressedFill : Style.selectedAccentFill
            border.width: Style.normalBorderWidth
            border.color: Style.normalBorderColor
            Text {
              anchors.centerIn: parent
              text: "Sign in with Google"
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            MouseArea {
              id: maSignIn
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.launchSetup()
            }
          }

          Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Style.space(120)
            height: Style.spacing.controlHeight
            radius: Style.cornerRadius / 2
            visible: root.hasSecret
            color: maRetry.containsMouse ? Style.hoverFill : "transparent"
            border.width: Style.normalBorderWidth
            border.color: Style.normalBorderColor
            Text {
              anchors.centerIn: parent
              text: "Retry"
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            MouseArea {
              id: maRetry
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.authNeeded = false
                root.notice = ""
                root.refreshAll()
              }
            }
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.apiDisabled
            text: "console.cloud.google.com → APIs & Services → Google Tasks API"
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      // The first-party dialog, rather than a hand-rolled overlay: it owns its
      // own focus, arrow/Tab selection and scrim-click-to-cancel.
      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        opened: root.mode === "confirm"
        message: root.confirmKind === "delete"
          ? "Delete this task?"
          : "Permanently clear completed tasks?"
        confirmText: root.confirmKind === "delete" ? "Delete" : "Clear"
        cancelText: "Cancel"
        background: Color.background
        foreground: Color.popups.text
        fontFamily: Style.font.family
        onConfirmed: root.confirmAction()
        onCanceled: root.cancelConfirm()
      }

      Rectangle {
        id: helpOverlay
        anchors.fill: parent
        visible: root.mode === "help"
        color: Qt.alpha(Color.background, 0.95)
        radius: Style.cornerRadius

        Column {
          anchors.centerIn: parent
          spacing: Style.spacing.lg

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "keys"
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            font.weight: Font.DemiBold
          }

          Grid {
            anchors.horizontalCenter: parent.horizontalCenter
            columns: 2
            columnSpacing: Style.space(18)
            rowSpacing: Style.spacing.xs

            Repeater {
              model: [
                ["j / k  ↑ ↓", "move cursor"],
                ["g / G", "jump to top / bottom"],
                ["↵ / space", "complete · reopen"],
                ["a", "add task (title, notes, due, time)"],
                ["e", "edit title, notes, due, time"],
                ["d / x", "delete task"],
                ["J / K", "reorder down / up"],
                ["h / l  ← →", "switch task list"],
                ["/", "filter tasks"],
                ["r", "sync with Google"],
                ["c", "clear completed"],
                ["q / esc", "close panel"]
              ]

              Row {
                required property var modelData
                spacing: Style.space(10)

                Text {
                  width: Style.space(78)
                  text: modelData[0]
                  color: Color.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Text {
                  text: modelData[1]
                  color: Color.popups.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "any key or click closes"
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        MouseArea {
          anchors.fill: parent
          onClicked: root.closeHelp()
        }
      }

      Rectangle {
        id: calOverlay
        anchors.fill: parent
        visible: root.calendarOpen
        color: Qt.alpha(Color.background, 0.97)
        radius: Style.cornerRadius

        MouseArea {
          anchors.fill: parent
          onClicked: root.closeCalendar()
        }

        Column {
          anchors.centerIn: parent
          spacing: Style.spacing.md
          width: Math.min(parent.width - Style.space(32), Style.space(296))

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.spacing.lg

            Rectangle {
              width: Style.space(24)
              height: Style.space(24)
              radius: Style.cornerRadius / 2
              color: maCalPrev.containsMouse ? Style.hoverFill : "transparent"
              Text {
                anchors.centerIn: parent
                text: "\uf104"
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
              MouseArea {
                id: maCalPrev
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.calMonth--
                  if (root.calMonth < 0) { root.calMonth = 11; root.calYear-- }
                }
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: Tasks.monthLabel(root.calYear, root.calMonth)
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.weight: Font.DemiBold
            }

            Rectangle {
              width: Style.space(24)
              height: Style.space(24)
              radius: Style.cornerRadius / 2
              color: maCalNext.containsMouse ? Style.hoverFill : "transparent"
              Text {
                anchors.centerIn: parent
                text: "\uf105"
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
              MouseArea {
                id: maCalNext
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.calMonth++
                  if (root.calMonth > 11) { root.calMonth = 0; root.calYear++ }
                }
              }
            }
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 2

            Repeater {
              model: 7
              Text {
                width: calGrid.cellW
                height: Style.space(20)
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: Qt.locale().dayName((((modelData + root.weekStart - 1) % 7) + 7) % 7 + 1, Locale.ShortFormat)
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          Grid {
            id: calGrid
            anchors.horizontalCenter: parent.horizontalCenter
            columns: 7
            columnSpacing: 2
            rowSpacing: 2

            readonly property int cellW: (parent.width - 12) / 7

            Repeater {
              model: Tasks.monthGrid(root.calYear, root.calMonth, root.weekStart)

              Rectangle {
                required property var modelData
                width: calGrid.cellW
                height: Style.space(28)
                radius: Style.cornerRadius / 3
                color: {
                  var cur = Tasks.keyForDate(root.calCursor)
                  if (modelData.date === cur) return Style.selectedAccentFill
                  if (maCell.containsMouse) return Style.hoverFill
                  return "transparent"
                }
                border.width: modelData.date === Tasks.keyForDate(new Date()) ? Style.normalBorderWidth : 0
                border.color: Color.accent
                opacity: modelData.inMonth ? 1 : 0.4

                Text {
                  anchors.centerIn: parent
                  text: modelData.day
                  color: modelData.date === Tasks.keyForDate(root.calCursor)
                    ? Color.popups.text
                    : (modelData.inMonth ? Color.foreground : Color.muted)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.weight: modelData.date === Tasks.keyForDate(new Date()) ? Font.DemiBold : Font.Normal
                }

                MouseArea {
                  id: maCell
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.calCursor = new Date(root.calYear, root.calMonth, modelData.day)
                    root.pickCalendarDate()
                  }
                }
              }
            }
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "↵ pick · arrows move · esc close"
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
