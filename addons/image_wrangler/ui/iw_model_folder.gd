@tool
extends VBoxContainer

## The Neural layer's model folder: a path to type or browse for, what is wrong with it, and
## a button that fetches a model into it.
##
## [b]Its own control rather than a plain string row.[/b] The folder is the one setting in
## the addon that can be filled in correctly and still be wrong, because what has to be in it
## is a pair of files nothing ships. So the three things belong together: where to look, what
## is missing, and the one press that fixes it.
##
## The download reports through Callables the dock hands over — see [method bind_download].
## Nothing here can reach the preview, and the preview is where a spinner belongs.

## Emitted when the folder is typed, picked or filled by a download.
##
## Its own signal rather than a Callable handed in, matching every other control the builder
## leaves for the dock to wire — the dock is the only thing that knows what an edit costs.
signal folder_changed

## Where the model comes from.
##
## A source archive rather than a release binary, because that tag is what the converted
## model is published under. What is inside it is whatever the repository holds — see
## [method _extract], which does not assume a shape.
const MODEL_URL := "https://github.com/klutch/deepbump-ncnn/archive/refs/tags/release.zip"

## What the archive is called on the way down. Removed once it has been unpacked.
const ZIP_NAME := "release.zip"

## Caption width, matching [constant IWSettingsBuilder.LABEL_WIDTH] so this row lines up
## with every other row in the form.
const LABEL_WIDTH := 92

## How the whole job is divided between its three parts.
##
## The download is nearly all of it in wall-clock terms — thirteen megabytes against a
## handful of file writes — so it gets nearly all of the bar. A bar that raced to 90% and
## then sat there would be saying the opposite of what is happening.
const DOWNLOAD_SHARE := 0.88
const EXTRACT_SHARE := 0.11

## Refused above this, so a redirect to something enormous cannot fill the disk. The model
## is around thirteen megabytes.
const MAX_DOWNLOAD_BYTES := 256 * 1024 * 1024

## What the archive is assumed to weigh when the server will not say.
##
## [b]Only ever a fallback.[/b] A forge serves a source archive as it builds it, so there is
## no length in the header to measure against — and a bar that sat at nothing for twelve
## megabytes would be saying the download had stalled. The count beside it is the real number
## either way, so the estimate being off shows as a bar that arrives early or crawls at the
## end rather than as a wrong answer.
const ESTIMATED_DOWNLOAD_BYTES := 12 * 1024 * 1024

## How far the estimated bar is allowed to get, so it cannot claim to be finished before the
## bytes actually stop.
const ESTIMATE_CEILING := 0.99

var _operation: IWOperation
var _property: StringName

## Where the model goes when nothing has said otherwise, from the schema.
##
## Written into the setting the moment this control finds it empty, so what is on screen and
## what gets saved are the same thing — a settings file from before the property had a
## default carries an empty one, and a blank row saying nothing is worse than a filled one
## saying where the model would go.
var _fallback := ""

var _field: LineEdit
var _browse: Button
var _download: Button
var _warning: Label
var _dialog: FileDialog
var _http: HTTPRequest

## Whether a download is in flight, which is what stops a second one starting on top of it.
var _busy := false

## Whether the card this sits on is switched on.
var _interactive := true

## Where the archive is being written, held between starting the request and being told it
## finished — the folder can be typed into while the bytes are coming down.
var _target_dir := ""

## Called as [code]begin(title)[/code], [code]step(overall, fraction, label)[/code] and
## [code]finish(message, ok)[/code]. Supplied by the dock; see [method bind_download].
var _begin := Callable()
var _step := Callable()
var _finish := Callable()


func setup(operation: IWOperation, property: StringName, fallback := "") -> void:
    _operation = operation
    _property = property
    _fallback = fallback
    _settle()
    _build()
    refresh()


## Puts the fallback into an empty setting, so nothing downstream has to know about it.
func _settle() -> void:
    if not _fallback.is_empty() and _raw().strip_edges().is_empty():
        _write(_fallback)


## Hands over the three ways this reports, which all end at the preview's overlay.
##
## Left unwired by the settings builder for the reason the pick controls are: the builder
## lays out settings and knows nothing about the dock, and the form is rebuilt often enough
## that the binding has to be redone rather than made once.
func bind_download(begin: Callable, step: Callable, finish: Callable) -> void:
    _begin = begin
    _step = step
    _finish = finish


func _build() -> void:
    var row := HBoxContainer.new()
    add_child(row)

    var caption := Label.new()
    caption.text = "Model Folder"
    caption.custom_minimum_size = Vector2(LABEL_WIDTH, 0)
    caption.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
    row.add_child(caption)

    _field = LineEdit.new()
    _field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _field.text = _stored()
    _field.text_changed.connect(_on_typed)
    row.add_child(_field)

    # Narrow and wordless. The row is already at the width the dock can give it, and a
    # button saying "Browse" would take that width off the path it is about.
    _browse = Button.new()
    _browse.text = "..."
    _browse.tooltip_text = "Pick the folder holding the model."
    _browse.pressed.connect(_on_browse)
    row.add_child(_browse)

    _warning = Label.new()
    _warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _warning.add_theme_font_size_override("font_size", 10)
    # The same amber a stack entry's prerequisite note uses, since it is saying the same
    # kind of thing: not broken, just not ready.
    _warning.modulate = Color(1.0, 0.85, 0.4)
    _warning.visible = false
    add_child(_warning)

    _download = Button.new()
    _download.text = "Download Latest Model"
    _download.tooltip_text = "Fetches the converted model and unpacks it into the folder above.\n\nAround thirteen megabytes. Anything already there under the same name is\noverwritten."
    _download.pressed.connect(_on_download)
    add_child(_download)

    # Off until there are bytes to count. Godot turns processing on for any node whose
    # script defines _process, and this one has nothing to do between downloads.
    set_process(false)


## What the setting holds, read at the moment it is asked for rather than cached — the dock
## swaps the settings Resource under this control without rebuilding it.
func _raw() -> String:
    var settings := _operation.get_settings() if _operation != null else null
    return String(settings.get(_property)) if settings != null else ""


## The folder this row is about: what the setting holds, or the fallback while it holds
## nothing. See [member _fallback].
func _stored() -> String:
    var held := _raw()
    return _fallback if held.strip_edges().is_empty() else held


func _write(value: String) -> void:
    var settings := _operation.get_settings() if _operation != null else null
    if settings != null:
        settings.set(_property, value)


## [b]Deliberately does not put the field back.[/b] Everything else here re-reads the setting
## into it, which is right when something else moved it — but doing that mid-edit would fight
## whoever is typing, because a field cleared back to nothing reads as the fallback.
func _on_typed(value: String) -> void:
    _write(value)
    _update_warning()
    _update_buttons()
    folder_changed.emit()


func _on_browse() -> void:
    if _dialog == null:
        _dialog = FileDialog.new()
        _dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
        _dialog.access = FileDialog.ACCESS_FILESYSTEM
        _dialog.title = "Pick the Model Folder"
        _dialog.dir_selected.connect(_on_picked)
        add_child(_dialog)
    var here := _resolved()
    if not here.is_empty() and DirAccess.dir_exists_absolute(here):
        _dialog.current_dir = here
    _dialog.popup_centered_ratio(0.6)


func _on_picked(path: String) -> void:
    _field.text = path
    _write(path)
    refresh()
    folder_changed.emit()


## The folder as something that can be opened, whatever was typed.
##
## [b]Globalised on the way out rather than on the way in.[/b] The default is a
## [code]res://[/code] path so it means the same thing in any checkout, and a folder picked
## through the dialog is an absolute one — this is where the two become the same kind of
## thing, and it leaves an absolute path alone.
func _resolved() -> String:
    var dir := _stored().strip_edges()
    return "" if dir.is_empty() else ProjectSettings.globalize_path(dir)


## Puts the row back in step with the setting behind it: the path, what is wrong with it, and
## what may be pressed.
func refresh() -> void:
    if _field == null:
        return
    if _field.text != _stored():
        _field.text = _stored()
    _update_warning()
    _update_buttons()


## Says what is wrong with the folder, or hides the line when nothing is.
func _update_warning() -> void:
    if _warning == null:
        return
    _warning.text = _trouble()
    _warning.visible = not _warning.text.is_empty()


## The one thing standing between this folder and a normal map, or empty when there is
## nothing.
func _trouble() -> String:
    if not _network_built():
        return "This build has no network to run, so no model would help. See tools/build_ncnn.py."
    var dir := _resolved()
    if dir.is_empty():
        return "No folder named. Point this at one and press Download Latest Model."
    if not DirAccess.dir_exists_absolute(dir):
        return "%s does not exist yet. Download Latest Model will make it." % _stored()
    if _model_in(dir).is_empty():
        return "No model here. Press Download Latest Model, or point this at a folder holding a .param with a .bin of the same name beside it."
    return ""


## Whether this build has the network wrapper at all.
##
## Asked of [ClassDB] rather than of [NormalNeural], so this control needs no reference to
## the one layer that happens to use it.
static func _network_built() -> bool:
    return ClassDB.class_exists(&"IWNormalNet")


## The [code].param[/code] of the first pair found directly in [param dir], or empty.
##
## The same rule the network itself applies — see [code]IWNormalNet::model_files[/code] —
## written out again here because the warning has to be right in a build that has no network
## class to ask.
static func _model_in(dir: String) -> String:
    var names := DirAccess.get_files_at(dir)
    names.sort()
    for name in names:
        if name.get_extension().to_lower() != "param":
            continue
        if names.has(name.get_basename() + ".bin"):
            return dir.path_join(name)
    return ""


func set_controls_enabled(value: bool) -> void:
    _interactive = value
    _update_buttons()


func _update_buttons() -> void:
    if _field == null:
        return
    var live := _interactive and not _busy
    _field.editable = live
    _browse.disabled = not live
    _download.disabled = not live or not _network_built()
    _download.text = "Downloading..." if _busy else "Download Latest Model"


# --- Fetching the model -------------------------------------------------

func _on_download() -> void:
    if _busy:
        return
    # [HTTPRequest] refuses to start from outside the tree, and a form being rebuilt is
    # briefly exactly that.
    if not is_inside_tree():
        _report("The form is still being built. Try again in a moment.", false)
        return
    var dir := _resolved()
    if dir.is_empty():
        _report("Name a model folder first.", false)
        return
    if not DirAccess.dir_exists_absolute(dir) \
            and DirAccess.make_dir_recursive_absolute(dir) != OK:
        _report("Could not make %s." % _stored(), false)
        return

    _target_dir = dir
    _busy = true
    _update_buttons()
    if _begin.is_valid():
        _begin.call("Downloading the model")
    _tell(0.0, 0.0, "Connecting to github.com")

    if _http == null:
        _http = HTTPRequest.new()
        # Off the main thread, so a slow connection does not make the dock feel stuck. The
        # signal still arrives on the main thread, which is where everything after it runs.
        _http.use_threads = true
        _http.request_completed.connect(_on_downloaded)
        add_child(_http)
    _http.download_file = dir.path_join(ZIP_NAME)

    var error := _http.request(MODEL_URL)
    if error != OK:
        _done("Could not start the download (error %d)." % error, false)
        return
    # Only while there are bytes to count. See _process.
    set_process(true)


## Counts the bytes down as they arrive.
##
## Polled rather than pushed, because [HTTPRequest] reports what it has by asking rather
## than by signalling. On for the length of one download and no longer.
func _process(_delta: float) -> void:
    if not _busy or _http == null:
        set_process(false)
        return
    var got := _http.get_downloaded_bytes()
    var total := _http.get_body_size()
    if total > MAX_DOWNLOAD_BYTES:
        _http.cancel_request()
        _done("The download is %s, which is far larger than a model. Stopped."
                % String.humanize_size(total), false)
        return
    if total > 0:
        var fraction := clampf(float(got) / float(total), 0.0, 1.0)
        _tell(fraction * DOWNLOAD_SHARE, fraction,
                "Downloading %s of %s"
                        % [String.humanize_size(got), String.humanize_size(total)])
        return
    # No length in the header, so the bar runs against an estimate and the label carries the
    # only number anybody can rely on. See ESTIMATED_DOWNLOAD_BYTES.
    var guessed := clampf(float(got) / float(ESTIMATED_DOWNLOAD_BYTES), 0.0, ESTIMATE_CEILING)
    _tell(guessed * DOWNLOAD_SHARE, guessed, "Downloading %s" % String.humanize_size(got))


func _on_downloaded(result: int, code: int, _headers: PackedStringArray,
        _body: PackedByteArray) -> void:
    set_process(false)
    var zip := _target_dir.path_join(ZIP_NAME)
    if result != HTTPRequest.RESULT_SUCCESS:
        _scrub(zip)
        _done("The download failed (result %d)." % result, false)
        return
    if code != 200:
        _scrub(zip)
        _done("github.com answered %d rather than handing over the file." % code, false)
        return

    _tell(DOWNLOAD_SHARE, 1.0, "Downloaded")
    _extract(zip)


## Unpacks [param zip] into the model folder, then tidies up after itself.
##
## Written out file by file rather than in one go, so the bar moves while it happens and so
## an entry that would land outside the folder can be refused. A frame is yielded between
## files: the writes are quick but the decompression is not, and a bar nobody sees move is
## the same as no bar.
func _extract(zip: String) -> void:
    var reader := ZIPReader.new()
    if reader.open(zip) != OK:
        _scrub(zip)
        _done("The file that came down is not a zip.", false)
        return

    var entries := reader.get_files()
    var lead := _common_lead(entries)
    var written := 0
    var failed := ""

    for i in entries.size():
        var entry: String = entries[i]
        # A directory entry is the folder its files name anyway, so it is made by the file
        # rather than by itself — and it is not worth a line on the bar.
        if entry.ends_with("/"):
            continue
        var relative := entry.substr(lead.length()) if not lead.is_empty() else entry
        relative = relative.lstrip("/")
        if relative.is_empty():
            continue
        # A zip that names its way back out of the folder it is being unpacked into is not
        # one to trust with a write.
        if relative.begins_with("/") or relative.contains("..") or relative.contains(":"):
            continue

        var reached := float(i + 1) / maxf(float(entries.size()), 1.0)
        _tell(DOWNLOAD_SHARE + EXTRACT_SHARE * reached, reached,
                "Unpacking %s" % relative.get_file())
        await get_tree().process_frame

        var destination := _target_dir.path_join(relative)
        var folder := destination.get_base_dir()
        if not DirAccess.dir_exists_absolute(folder) \
                and DirAccess.make_dir_recursive_absolute(folder) != OK:
            failed = relative
            break
        var file := FileAccess.open(destination, FileAccess.WRITE)
        if file == null:
            failed = relative
            break
        file.store_buffer(reader.read_file(entry))
        file.close()
        written += 1

    reader.close()

    if not failed.is_empty():
        _scrub(zip)
        _done("Could not write %s out of the archive." % failed, false)
        return
    if written == 0:
        _scrub(zip)
        _done("The archive held no files.", false)
        return

    _tell(DOWNLOAD_SHARE + EXTRACT_SHARE, 1.0, "Unpacked %d files" % written)
    await get_tree().process_frame

    # The repository decides how deep the pair sits, and the network only looks in the one
    # folder it is given — so wherever they landed, they come up to the top.
    var lifted := _lift_model()
    _scrub(zip)
    _tell(1.0, 1.0, "Done")

    if _model_in(_target_dir).is_empty():
        _done("The archive came down and unpacked, but holds no .param with a .bin beside it.",
                false)
        return
    var where := _stored() if lifted.is_empty() else "%s, %s" % [_stored(), lifted]
    _done("Model ready in %s." % where, true)


## The folder every entry in [param entries] sits under, or empty when they do not share one.
##
## A source archive from a forge puts everything under one directory named for the tag, and
## unpacking that verbatim would leave the model one folder below where the network looks.
## Measured rather than assumed, so an archive packed the other way is left as it is.
static func _common_lead(entries: PackedStringArray) -> String:
    if entries.is_empty():
        return ""
    var lead := String(entries[0]).split("/")[0]
    if lead.is_empty():
        return ""
    for entry in entries:
        if not String(entry).begins_with(lead + "/"):
            return ""
    return lead + "/"


## Brings the model pair up out of whatever subfolder it was packed in.
##
## Returns a line saying where it was moved from, or empty when it was already in the right
## place. The pair is moved rather than the folder flattened: everything else in the archive
## is a licence or a readme and belongs where it was put.
func _lift_model() -> String:
    if not _model_in(_target_dir).is_empty():
        return ""
    var found := _find_model(_target_dir, 0)
    if found.is_empty():
        return ""
    var base := found.get_basename()
    for extension: String in [".param", ".bin"]:
        var from: String = base + extension
        var to := _target_dir.path_join(from.get_file())
        if FileAccess.file_exists(to):
            DirAccess.remove_absolute(to)
        if DirAccess.rename_absolute(from, to) != OK:
            return ""
    return "moved up from %s" % found.get_base_dir().get_file()


## The first [code].param[/code] with a [code].bin[/code] beside it anywhere under
## [param dir]. Depth-limited, since a model three folders down is a surprise rather than a
## layout worth chasing.
static func _find_model(dir: String, depth: int) -> String:
    var here := _model_in(dir)
    if not here.is_empty():
        return here
    if depth >= 3:
        return ""
    var folders := DirAccess.get_directories_at(dir)
    folders.sort()
    for folder in folders:
        var found := _find_model(dir.path_join(folder), depth + 1)
        if not found.is_empty():
            return found
    return ""


func _scrub(zip: String) -> void:
    if FileAccess.file_exists(zip):
        DirAccess.remove_absolute(zip)


## One step of the job, as a share of the whole and a share of this part of it.
func _tell(overall: float, fraction: float, label: String) -> void:
    if _step.is_valid():
        _step.call(overall, fraction, label)


func _done(message: String, ok: bool) -> void:
    _busy = false
    _target_dir = ""
    set_process(false)
    if _finish.is_valid():
        _finish.call(message, ok)
    refresh()
    if ok:
        folder_changed.emit()


## Says something that never got as far as starting a download.
func _report(message: String, ok: bool) -> void:
    if _finish.is_valid():
        _finish.call(message, ok)
