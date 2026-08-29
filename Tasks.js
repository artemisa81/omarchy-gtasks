.pragma library

function pad2(n) {
    var v = Number(n)
    return v < 10 ? "0" + v : String(v)
}

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

// Time of day lives in the notes, because the Tasks API has nowhere else to put
// it: the time portion of `due` is discarded on write and cannot be read back.
// A trailing "\u23f0 HH:MM" line is the carrier. It round-trips through Google
// untouched, so the time is legible on the web and on a phone, and it is split
// back out here so the rest of the panel only ever sees clean notes and a
// separate `time`.
var TIME_MARK = "\u23f0"
var TIME_RE = /\n*\u23f0[ \t]*(\d{1,2}):(\d{2})[ \t]*$/

function splitNotes(rawNotes) {
    var text = String(rawNotes || "")
    var m = text.match(TIME_RE)
    if (!m) return { notes: text, time: "" }
    var h = Number(m[1]), min = Number(m[2])
    if (h < 0 || h > 23 || min < 0 || min > 59) return { notes: text, time: "" }
    return {
        notes: text.replace(TIME_RE, ""),
        time: pad2(h) + ":" + pad2(min)
    }
}

function joinNotes(notes, time) {
    var body = String(notes || "").replace(/\s+$/, "")
    var t = parseClock(time)
    if (t === "") return body
    return body === "" ? TIME_MARK + " " + t : body + "\n\n" + TIME_MARK + " " + t
}

// Accepts 9:5, 09:05, 0905, 930 — anything that reads unambiguously as a clock
// time — and normalises it to HH:MM. Returns "" for anything that does not.
function parseClock(text) {
    var raw = String(text || "").replace(/\s+/g, "")
    if (raw === "") return ""
    var m = raw.match(/^(\d{1,2}):(\d{1,2})$/)
    if (!m) {
        var digits = raw.match(/^(\d{3,4})$/)
        if (!digits) return ""
        var d = digits[1]
        m = [null, d.slice(0, d.length - 2), d.slice(-2)]
    }
    var h = Number(m[1]), min = Number(m[2])
    if (isNaN(h) || isNaN(min) || h < 0 || h > 23 || min < 0 || min > 59) return ""
    return pad2(h) + ":" + pad2(min)
}

function normalizeTask(raw) {
    if (!raw || typeof raw !== "object") return null
    var id = String(raw.id || "")
    if (id === "") return null
    if (raw.deleted === true) return null
    var split = splitNotes(raw.notes)
    return {
        id: id,
        title: String(raw.title || ""),
        notes: split.notes,
        time: split.time,
        status: raw.status === "completed" ? "completed" : "needsAction",
        due: raw.due ? String(raw.due) : "",
        updated: raw.updated ? String(raw.updated) : "",
        position: String(raw.position || ""),
        parent: raw.parent ? String(raw.parent) : ""
    }
}

// Epoch millis for a task's due date at its time of day, in local time. Returns
// 0 when the task has no date, or a date but no time — an all-day task has no
// moment to fire an alert at.
function dueMoment(task) {
    if (!task || !task.due || !task.time) return 0
    var d = String(task.due).match(/^(\d{4})-(\d{2})-(\d{2})/)
    var t = String(task.time).match(/^(\d{2}):(\d{2})$/)
    if (!d || !t) return 0
    var when = new Date(Number(d[1]), Number(d[2]) - 1, Number(d[3]), Number(t[1]), Number(t[2]), 0, 0)
    return isNaN(when.getTime()) ? 0 : when.getTime()
}

function parseTasksResponse(raw) {
    var out = []
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].replace(/^\s+|\s+$/g, "")
        if (line === "") continue
        var page = null
        try { page = JSON.parse(line) } catch (e) { continue }
        var items = page && page.items ? page.items : []
        for (var j = 0; j < items.length; j++) {
            var t = normalizeTask(items[j])
            if (t) out.push(t)
        }
    }
    return out
}

function parseTasklists(raw) {
    var out = []
    var doc = null
    try { doc = JSON.parse(String(raw || "")) } catch (e) { return out }
    var items = doc && doc.items ? doc.items : []
    for (var i = 0; i < items.length; i++) {
        var item = items[i]
        if (!item || !item.id) continue
        out.push({ id: String(item.id), title: String(item.title || "Untitled list") })
    }
    return out
}

function depthOf(task, byId, memo) {
    if (!task.parent) return 0
    if (memo[task.id] !== undefined) return memo[task.id]
    memo[task.id] = 1
    var parentTask = byId[task.parent]
    var d = parentTask ? 1 + depthOf(parentTask, byId, memo) : 0
    memo[task.id] = d
    return d
}

function dueKey(task) {
    if (!task.due) return "9999"
    var m = String(task.due).match(/^(\d{4})-(\d{2})-(\d{2})/)
    return m ? m[1] + m[2] + m[3] : "9999"
}

function buildRows(tasks, opts) {
    var showCompleted = !opts || opts.showCompleted !== false
    var filter = opts && opts.filter ? String(opts.filter).toLowerCase() : ""

    var byId = {}
    for (var i = 0; i < tasks.length; i++) byId[tasks[i].id] = tasks[i]

    var open = []
    var done = []
    var matches = {}
    for (var j = 0; j < tasks.length; j++) {
        var t = tasks[j]
        if (filter !== "") {
            var hay = (t.title + "\n" + t.notes).toLowerCase()
            if (hay.indexOf(filter) === -1) continue
        }
        matches[t.id] = true
        ;(t.status === "completed" ? done : open).push(t)
    }

    function orderCmp(a, b) {
        if (a.position < b.position) return -1
        if (a.position > b.position) return 1
        return 0
    }
    function dueCmp(a, b) {
        var ka = dueKey(a), kb = dueKey(b)
        if (ka !== kb) return ka < kb ? -1 : 1
        return orderCmp(a, b)
    }
    function titleCmp(a, b) {
        var la = a.title.toLowerCase(), lb = b.title.toLowerCase()
        if (la !== lb) return la < lb ? -1 : 1
        return orderCmp(a, b)
    }
    var cmp = orderCmp
    if (opts && opts.sort === "due") cmp = dueCmp
    else if (opts && opts.sort === "title") cmp = titleCmp

    open.sort(cmp)
    done.sort(function(a, b) { return orderCmp(b, a) })

    var ordered = open.concat(done)
    var memo = {}
    var rows = []
    for (var k = 0; k < ordered.length; k++) {
        var task = ordered[k]
        if (!showCompleted && task.status === "completed") continue
        rows.push({
            task: task,
            depth: depthOf(task, byId, memo)
        })
    }
    return rows
}

function counts(tasks) {
    var open = 0, total = 0
    for (var i = 0; i < tasks.length; i++) {
        total++
        if (tasks[i].status !== "completed") open++
    }
    return { open: open, total: total }
}

function totals(tasksByList) {
    var open = 0, total = 0
    for (var key in tasksByList) {
        var c = counts(tasksByList[key] || [])
        open += c.open
        total += c.total
    }
    return { open: open, total: total }
}

function parseDueIso(iso) {
    var m = String(iso || "").match(/^(\d{4})-(\d{2})-(\d{2})/)
    if (!m) return null
    return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]))
}

function keyForDate(d) {
    if (!d || isNaN(d.getTime())) return ""
    return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate())
}

var MONTH_NAMES = ["January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December"]

function monthLabel(year, month) {
    return MONTH_NAMES[month] + " " + year
}

function monthGrid(year, month, weekStart) {
    var first = new Date(year, month, 1)
    var offset = (first.getDay() - weekStart + 7) % 7
    var cells = []
    var start = new Date(year, month, 1 - offset)
    for (var i = 0; i < 42; i++) {
        var d = new Date(start.getFullYear(), start.getMonth(), start.getDate() + i)
        cells.push({
            day: d.getDate(),
            date: keyForDate(d),
            inMonth: d.getMonth() === month
        })
    }
    return cells
}

// Google Tasks stores a due DATE, never a time: the API discards the time
// portion on write and has no way to read one back. So every due value here is
// handled as the literal YYYY-MM-DD prefix of the timestamp — never through
// `new Date(iso)`, which would reinterpret the UTC midnight in local time and
// shift the day for anyone west of UTC.
function dueParts(iso) {
    var m = String(iso || "").match(/^(\d{4})-(\d{2})-(\d{2})/)
    return { date: m ? m[1] + "-" + m[2] + "-" + m[3] : "" }
}

function composeDue(date) {
    var m = String(date || "").match(/^(\d{4})-(\d{1,2})-(\d{1,2})$/)
    if (!m) return ""
    var year = Number(m[1]), month = Number(m[2]), day = Number(m[3])
    if (month < 1 || month > 12 || day < 1 || day > 31) return ""
    // Round-trips through Date so that 2026-02-31 is rejected rather than sent.
    var probe = new Date(year, month - 1, day)
    if (probe.getFullYear() !== year || probe.getMonth() !== month - 1 || probe.getDate() !== day) return ""
    return year + "-" + pad2(month) + "-" + pad2(day) + "T00:00:00.000Z"
}

function formatDue(iso, today, time) {
    var d = parseDueIso(iso)
    if (!d) return ""
    var label = MONTHS[d.getMonth()] + " " + d.getDate()
    if (!today || d.getFullYear() !== today.getFullYear())
        label += " '" + String(d.getFullYear()).substr(2)
    if (time) label += " " + time
    return label
}

function isOverdue(iso, today) {
    var d = parseDueIso(iso)
    if (!d || !today) return false
    var t0 = new Date(today.getFullYear(), today.getMonth(), today.getDate())
    return d.getTime() < t0.getTime()
}

function isDueToday(iso, today) {
    var d = parseDueIso(iso)
    if (!d || !today) return false
    return d.getFullYear() === today.getFullYear()
        && d.getMonth() === today.getMonth()
        && d.getDate() === today.getDate()
}
