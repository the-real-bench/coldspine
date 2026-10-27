extends Node
## SESSION LOG (release-readiness / CRITIC#7) — lightweight crash/error capture for a permadeath
## game whose determinism makes every field failure reproducible from (seed, trace).
##
## AUTOLOAD (`SessionLog` in project.godot). Each process writes `user://logs/session-<n>.log`
## (a RING OF 5 — oldest sessions are pruned at startup). The log captures:
##   - a header: app version, engine version, OS, wall-clock start time;
##   - every push_error / push_warning / SCRIPT ERROR / shader error, with file:line and
##     script backtraces, via a custom `Logger` registered through `OS.add_logger()` (Godot 4.5+);
##   - the SEED of the active run — auto-detected when a run_controller node enters the tree
##     (read-only observation; nothing here touches the run layer), plus a public API.
##
## PUBLIC API (for the run layer / batch 3):
##   SessionLog.note(msg: String)                  — append a free-form line (e.g. car-resolution trace).
##   SessionLog.log_run_start(seed: int, extra="") — record the active run's seed explicitly.
##
## SILENCE CONTRACT: this node NEVER prints to stdout and never push_error()s on its own behalf —
## the headless test suites parse real stdout and must stay byte-stable. All disk failures are
## swallowed (logging is best-effort; it can never wedge the game). Writes are flushed per line so
## a hard crash keeps everything up to the failing statement.

const LOG_DIR := "user://logs"
const LOG_PREFIX := "session-"
const LOG_EXT := ".log"
const MAX_SESSIONS := 5          # the ring: keep at most this many session logs

var _file: FileAccess = null
var _mutex := Mutex.new()
var _logger: SessionFileLogger = null


## The OS-level capture hook: receives every push_error/push_warning/script/shader error the
## engine reports (errors keep flowing to the console as normal — this only ADDS the file sink).
class SessionFileLogger extends Logger:
	var owner_log = null   # the SessionLog autoload (untyped to avoid a cyclic class reference)

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, script_backtraces) -> void:
		if owner_log == null:
			return
		var kind := "ERROR"
		match error_type:
			ERROR_TYPE_WARNING: kind = "WARNING"
			ERROR_TYPE_SCRIPT: kind = "SCRIPT ERROR"
			ERROR_TYPE_SHADER: kind = "SHADER ERROR"
		var what := rationale if rationale != "" else code
		var suffix := "" if (code == "" or code == what) else " (%s)" % code
		owner_log._append("%s: %s%s at %s:%d in %s()" % [kind, what, suffix, file, line, function])
		if script_backtraces != null:
			for bt in script_backtraces:
				if bt != null and not bt.is_empty():
					owner_log._append("    backtrace: " + bt.format(8))


func _init() -> void:
	_open_session_file()
	if _file != null:
		_logger = SessionFileLogger.new()
		_logger.owner_log = self
		OS.add_logger(_logger)


func _ready() -> void:
	# Auto-detect the active run's seed: observe run_controller nodes entering the tree (read-only —
	# no run-layer code changes). consume_handoff() sets the seed in _ready, so read one frame later.
	get_tree().node_added.connect(_on_node_added)


func _exit_tree() -> void:
	if _logger != null:
		OS.remove_logger(_logger)
		_logger = null
	_mutex.lock()
	if _file != null:
		_file.close()
		_file = null
	_mutex.unlock()


# --- public API ------------------------------------------------------------------
## Append a free-form line to the session log (best-effort, never fails loudly).
func note(msg: String) -> void:
	_append(msg)


## Record the active run's seed (the reproducibility key). `extra` carries anything else useful
## (squad size, resume flag, ...). The run layer may call this directly; the node_added observer
## below covers the current controller without touching it.
func log_run_start(seed: int, extra: String = "") -> void:
	_append("RUN seed=%d (0x%X)%s" % [seed, seed, (" " + extra) if extra != "" else ""])


# --- run detection (read-only observation) ----------------------------------------
func _on_node_added(node: Node) -> void:
	var s = node.get_script()
	if s == null or not (s is Script):
		return
	if String(s.resource_path).ends_with("/run_controller.gd"):
		_log_controller_seed.call_deferred(node)


func _log_controller_seed(node: Node) -> void:
	if node == null or not is_instance_valid(node):
		return
	if ("seed" in node):
		var extra := ""
		if ("sim_mode" in node):
			extra = "sim_mode=%s" % str(node.sim_mode)
		log_run_start(int(node.seed), extra)


# --- file plumbing -----------------------------------------------------------------
func _open_session_file() -> void:
	var d := DirAccess.open("user://")
	if d == null:
		return
	if not d.dir_exists("logs"):
		if d.make_dir("logs") != OK:
			return
	var logs := DirAccess.open(LOG_DIR)
	if logs == null:
		return
	# Collect existing session indices, prune the oldest beyond the ring, pick the next index.
	var indices: Array = []
	for f in logs.get_files():
		if f.begins_with(LOG_PREFIX) and f.ends_with(LOG_EXT):
			var n := f.trim_prefix(LOG_PREFIX).trim_suffix(LOG_EXT)
			if n.is_valid_int():
				indices.append(int(n))
	indices.sort()
	while indices.size() >= MAX_SESSIONS:
		logs.remove(LOG_PREFIX + str(indices.pop_front()) + LOG_EXT)   # best-effort prune
	var next: int = (indices.back() + 1) if not indices.is_empty() else 1
	_file = FileAccess.open("%s/%s%d%s" % [LOG_DIR, LOG_PREFIX, next, LOG_EXT], FileAccess.WRITE)
	if _file == null:
		return
	var v := Engine.get_version_info()
	_append("COLDSPINE session log — app v%s | Godot %s | %s | started %s" % [
		str(ProjectSettings.get_setting("application/config/version", "?")),
		str(v.get("string", "?")), OS.get_name(),
		Time.get_datetime_string_from_system(false, true)])


## The single write path — mutexed (Logger callbacks may arrive from any thread), timestamped,
## flushed per line so a crash loses nothing already reported.
func _append(line: String) -> void:
	_mutex.lock()
	if _file != null:
		_file.store_line("[%s] %s" % [Time.get_time_string_from_system(), line])
		_file.flush()
	_mutex.unlock()
