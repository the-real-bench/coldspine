class_name SaveSystem
## PERSISTENCE (GDD §14 / §7.4) — JSON save/load to `user://`, the one place the game touches the
## disk. Two payloads:
##   1. the persistent META PROFILE (MetaProfile) — currency / unlocks / Memorial / settings;
##   2. an optional MID-RUN save of the current RunState (save/resume via its dict round-trip).
##
## ROBUSTNESS CONTRACT: load NEVER throws. A missing file, an unreadable file, malformed JSON, or
## a non-Dictionary top level all fall back gracefully — a FRESH MetaProfile for the profile, or
## `null` for "no run to resume". Corruption can never wedge the player out of the main menu.
##
## ATOMIC SAVE-SLOT CONTRACT (release-readiness #5): every write goes tmp-then-swap (`.tmp` written
## fully, previous good save kept as `.bak`, then swapped in) so an OS kill mid-write can never
## truncate the live file. On a CORRUPT load the slot recovers from `.bak` (the corrupt file is
## preserved as `.corrupt` for forensics, the recovery is re-persisted, and the failure is SURFACED
## via push_warning) instead of silently erasing progress. A cleanly MISSING file is still just
## "no save" — deletion stays deliberate. Generic primitives: save_slot / load_slot / clear_slot.
##
## SAVE SANDBOX (harness safety): `--save-sandbox` / COLDSPINE_SAVE_SANDBOX=1 diverts the profile
## and run-save paths to "sandbox_"-prefixed files (see the seam below) so harness runs never touch
## the owner's real saves.
##
## RRefCounted statics, NO SceneTree. This file MAY use Strings/Dictionaries/JSON freely (it is
## the persistence boundary, outside the integer sim) — but it round-trips RunState through
## RunState.to_dict/from_dict, which re-coerce their own ints on load so no float leaks into core.

const MetaProfile = preload("res://core/meta/meta_profile.gd")
const RunStateClass = preload("res://core/run/run_state.gd")

const PROFILE_PATH := "user://coldspine_profile.json"
const RUN_PATH     := "user://coldspine_run.json"

# ---- SAVE SANDBOX (harness safety, W1-9) ---------------------------------------
# When the process carries `--save-sandbox` on its command line (or COLDSPINE_SAVE_SANDBOX=1 in the
# environment), EVERY SaveSystem path gains a "sandbox_" filename prefix (same user:// dir, distinct
# files) so harness runs (e.g. the windowed screenshot tour) can never touch the owner's real
# profile / run saves. This is the SINGLE diversion seam: every API function below resolves its
# path through profile_path()/run_path() — grep "sandbox" to find every moving part.
const SANDBOX_PREFIX := "sandbox_"

## In-process arm (harness safety, W1-9b): a headless test runner sets this true in its own
## `_initialize` so EVERY SaveSystem write it triggers diverts to the sandbox_ files — the owner's
## real profile/run slots are then untouchable by that process even when a test pokes the raw path
## constants. Left false by default so the cmdline/env seam (and meta_smoke's default-off contract)
## are unchanged; a suite that must observe the true default simply never sets it.
static var force_sandbox: bool = false

## Is the save sandbox armed for this process? Armed by ANY of:
##   - `force_sandbox` set in-process (a harness `_initialize` opting in explicitly);
##   - the `--save-sandbox` cmdline flag or `COLDSPINE_SAVE_SANDBOX=1` env (the windowed-tour seam);
##   - AUTO: the process was launched to run a `res://tests/…​.gd` script (every headless suite + the
##     tour). This is the structural guarantee that NO test run — present or future, whichever suite —
##     can ever write the owner's real profile/run save: a suite reaches SaveSystem indirectly through
##     the menu/RunController game code, so opt-in-per-suite is not enough. The real game
##     (main_scene, no `--script res://tests/`) is never auto-sandboxed.
static func save_sandboxed() -> bool:
	if force_sandbox:
		return true
	var args := OS.get_cmdline_args()
	if args.has("--save-sandbox") or OS.get_environment("COLDSPINE_SAVE_SANDBOX") == "1":
		return true
	return _running_test_script(args)

## True when a `res://tests/….gd` path rides the command line (the `--script` target of a suite or
## the screenshot tour). Kept tiny + pure so the sandbox predicate stays trivially auditable.
static func _running_test_script(args: PackedStringArray) -> bool:
	for a in args:
		if a.begins_with("res://tests/") and a.ends_with(".gd"):
			return true
	return false

## The pure filename transform (always prefixes), independent of whether the sandbox is armed — so a
## test can assert the diversion shape without depending on its own (auto-sandboxed) process state.
static func sandbox_name(path: String) -> String:
	return path.get_base_dir().path_join(SANDBOX_PREFIX + path.get_file())

## The single path diversion: sandbox armed -> same dir, "sandbox_"-prefixed filename.
static func _sandbox_path(path: String) -> String:
	return sandbox_name(path) if save_sandboxed() else path

## The LIVE profile save path (sandbox-aware). All profile I/O below goes through this.
static func profile_path() -> String:
	return _sandbox_path(PROFILE_PATH)

## The LIVE mid-run save path (sandbox-aware). All run-slot I/O below goes through this.
static func run_path() -> String:
	return _sandbox_path(RUN_PATH)

# Save-slot sidecar suffixes (see the atomic save-slot contract above).
const TMP_EXT     := ".tmp"       # in-flight write; swapped in only once fully flushed
const BAK_EXT     := ".bak"       # the previous successful save (the corrupt-recovery source)
const CORRUPT_EXT := ".corrupt"   # a corrupt main file, preserved for forensics on recovery


# --- meta profile --------------------------------------------------------------
## Persist the profile to user://. Returns true on a successful write. Pretty-printed JSON so a
## human (or the owner) can eyeball the save.
static func save_profile(profile) -> bool:
	if profile == null:
		return false
	return _write_json(profile_path(), profile.to_dict())


## Load the profile from user://. ALWAYS returns a usable MetaProfile — recovered from the `.bak`
## backup if the main file is corrupt (surfaced via push_warning), or a fresh one only when there
## is genuinely nothing to recover (missing file, or corrupt with no usable backup).
static func load_profile() -> MetaProfile:
	var d = load_slot(profile_path())
	if d == null:
		return MetaProfile.new()   # fresh profile fallback (nothing recoverable)
	return MetaProfile.from_dict(d)


## True if a profile save exists on disk.
static func has_profile() -> bool:
	return FileAccess.file_exists(profile_path())


# --- mid-run save / resume -----------------------------------------------------
## Persist the in-progress RunState (the Continue slot). One slot; saving overwrites it. Returns
## true on a successful write.
static func save_run(run_state) -> bool:
	if run_state == null:
		return false
	return _write_json(run_path(), run_state.to_dict())


## True if a resumable mid-run save exists.
static func has_run_save() -> bool:
	return FileAccess.file_exists(run_path())


## The mid-run save's SCHEMA_VERSION as written on disk, or -1 when there is no save (or it is
## corrupt / predates the schema field). Pure read — never mutates or migrates (W7-3).
static func run_save_schema() -> int:
	var d = load_slot(run_path())
	if d == null or typeof(d) != TYPE_DICTIONARY or not d.has("schema"):
		return -1
	return int(d.get("schema", -1))


## True ONLY when a resumable save EXISTS and its schema matches the current RunState.SCHEMA_VERSION
## (W7-3). A save written by an incompatible build reads as NOT compatible, so the menu can disable
## CONTINUE with a clean message instead of resuming into a divergent (or crashing) run.
static func run_save_compatible() -> bool:
	if not has_run_save():
		return false
	return run_save_schema() == RunStateClass.SCHEMA_VERSION


## Load the mid-run RunState. Returns a rebuilt RunState — recovered from `.bak` if the main file
## is corrupt — or null if there is no save / nothing recoverable (Continue is simply unavailable
## — never a crash). W7-3: a save whose schema does not match (and cannot be migrated) is REFUSED
## gracefully (a push_warning, then null) — never silently loaded into a divergent run.
static func load_run():
	var d = load_slot(run_path())
	if d == null:
		return null
	# A run dict must at least carry a seed + line to be resumable; otherwise treat as corrupt.
	if not d.has("seed"):
		return null
	# W7-3 SCHEMA GATE — validate/migrate against the current RunState schema before rebuilding.
	var checked = _schema_check_run(d)
	if checked == null:
		return null
	return RunStateClass.from_dict(checked)


## Validate (and, in future, migrate) a loaded run dict against the current schema (W7-3). Returns
## the resumable dict when the schema matches, or null when it is incompatible and cannot be migrated
## — refusing cleanly (a surfaced warning) rather than silently diverging or crashing mid-resume.
## Only SCHEMA_VERSION is known today, so a mismatch is refused; add real migrations here as the
## schema evolves (branch on `schema`, transform `d`, return the upgraded dict).
static func _schema_check_run(d: Dictionary):
	var schema: int = int(d.get("schema", -1))
	if schema == RunStateClass.SCHEMA_VERSION:
		return d
	push_warning("COLDSPINE mid-run save schema %d != current %d — refusing to resume an incompatible save (start a new run)." % [schema, RunStateClass.SCHEMA_VERSION])
	return null


## Delete the mid-run save (call when a run ENDS — win or loss — so Continue clears). Idempotent.
## Clears the WHOLE slot (main + .tmp/.bak/.corrupt sidecars) — permadeath stays sacred: no
## backup of a finished run may ever resurrect it.
static func clear_run() -> void:
	clear_slot(run_path())


# ============================ SAVE-SLOT PRIMITIVES ==============================
## Generic atomic save-slot API (the persistence primitives the run layer builds on).
## A "slot" is a JSON file plus its .tmp/.bak/.corrupt sidecars.

## Atomically persist `data` to `path`: write `path.tmp` fully, keep the previous save as
## `path.bak`, then swap the tmp into place. An OS kill at ANY point leaves either the old save,
## or the old save + a completed tmp (recovered on the next load) — never a truncated file.
static func save_slot(path: String, data: Dictionary) -> bool:
	var tmp := path + TMP_EXT
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(data, "\t"))
	f.flush()
	f.close()
	var d := DirAccess.open(path.get_base_dir())
	if d == null:
		return false
	# Keep the previous good save as .bak (copy, so the main file stays live until the swap).
	if d.file_exists(path.get_file()):
		d.copy(path, path + BAK_EXT)
		d.remove(path.get_file())
	# Swap the fully-written tmp into place (rename to a now-free name — portable on all targets).
	return d.rename(tmp, path) == OK


## Load a slot. Returns the parsed Dictionary, or null when there is nothing usable. Recovery
## order on a CORRUPT main file: preserve it as `.corrupt`, restore from `.bak` (re-persisting it
## as the main file), and SURFACE the failure via push_warning — never a silent reset. A cleanly
## missing file is just "no save" (deletion stays deliberate); a missing main with a completed
## `.tmp` (a kill mid-swap) recovers the tmp.
static func load_slot(path: String):
	var d = _read_json(path)
	if d != null and typeof(d) == TYPE_DICTIONARY:
		return d
	if FileAccess.file_exists(path):
		# CORRUPT main file. Preserve the evidence, then try the previous good save.
		var dir := DirAccess.open(path.get_base_dir())
		if dir != null:
			if dir.file_exists(path.get_file() + CORRUPT_EXT):
				dir.remove(path.get_file() + CORRUPT_EXT)
			dir.rename(path, path + CORRUPT_EXT)
		var bak = _read_json(path + BAK_EXT)
		if bak != null and typeof(bak) == TYPE_DICTIONARY:
			save_slot(path, bak)   # re-persist the recovery so the next load is clean
			push_warning("COLDSPINE save '%s' was corrupt — recovered the previous save from backup (corrupt file kept as %s)." % [path, CORRUPT_EXT])
			return bak
		push_warning("COLDSPINE save '%s' was corrupt and no usable backup exists — starting fresh (corrupt file kept as %s)." % [path, CORRUPT_EXT])
		return null
	# Missing main: a completed .tmp means we were killed mid-swap — the newest save survives.
	var t = _read_json(path + TMP_EXT)
	if t != null and typeof(t) == TYPE_DICTIONARY:
		save_slot(path, t)
		push_warning("COLDSPINE save '%s' was interrupted mid-write — recovered the in-flight save." % path)
		return t
	return null


## Remove a slot and ALL its sidecars (main + .tmp/.bak/.corrupt). Idempotent.
static func clear_slot(path: String) -> void:
	for p in [path, path + TMP_EXT, path + BAK_EXT, path + CORRUPT_EXT]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
			# globalize can fail on some platforms for user://; fall back to the dir remove.
			if FileAccess.file_exists(p):
				var d := DirAccess.open(p.get_base_dir())
				if d != null:
					d.remove(p.get_file())


# --- io primitives (the corruption boundary) -----------------------------------
static func _write_json(path: String, data: Dictionary) -> bool:
	return save_slot(path, data)


## Read + parse a JSON file. Returns the parsed value, or null on ANY failure (missing, open
## error, parse error). This is the single point that swallows corruption.
static func _read_json(path: String):
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var txt := f.get_as_text()
	f.close()
	if txt.strip_edges() == "":
		return null
	# Use a JSON instance + .parse() (not the static parse_string) so malformed input returns an
	# error CODE quietly instead of spamming the error log — corruption is an expected, handled
	# case here, not a fault to surface. Returns the parsed value only on a clean parse.
	var j := JSON.new()
	var err := j.parse(txt)
	if err != OK:
		return null
	return j.data
