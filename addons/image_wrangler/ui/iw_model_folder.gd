@tool
extends VBoxContainer

## A model folder: a path to type or browse for, what is wrong with it, and a button that
## fetches a model into it.
##
## [b]Its own control rather than a plain string row.[/b] A folder here can be filled in
## correctly and still be wrong, because what has to be in it is files nothing ships. So the
## three things belong together: where to look, what is missing, and the one press that fixes
## it.
##
## Two arrangements, per [member _many_models]: a folder holding one model, or a folder
## holding a folder per model. And two ways of naming it — a setting the user can edit, via
## [method setup], or a path fixed in code, via [method setup_fixed].
##
## The download reports through Callables the dock hands over — see [method bind_download].
## Nothing here can reach the preview, and the preview is where a spinner belongs.

## Emitted when the folder is typed, picked or filled by a download.
##
## Its own signal rather than a Callable handed in, matching every other control the builder
## leaves for the dock to wire — the dock is the only thing that knows what an edit costs.
signal folder_changed

## Emitted when Refresh is pressed. What refreshing means is the dock's to decide, for the
## same reason [signal folder_changed] leaves it there.
signal refresh_requested

## Where the model comes from when the schema entry does not say.
##
## A source archive rather than a release binary, because that tag is what the converted
## model is published under. What is inside it is whatever the repository holds — see
## [method _extract], which does not assume a shape.
##
## Only a default: an operation whose model lives elsewhere carries a
## [code]download_url[/code] on its Model Folder schema entry, and one that carries the
## key [i]empty[/i] is saying no archive is published yet — the button then says so
## instead of fetching the wrong model. See [method setup].
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

## Refused above this, so a redirect to something enormous cannot fill the disk. Well clear
## of the largest archive anything here fetches, which is around forty-five megabytes.
const MAX_DOWNLOAD_BYTES := 256 * 1024 * 1024

## What the archive is assumed to weigh when neither the schema nor the server says.
##
## [b]Only ever a fallback.[/b] A forge serves a source archive as it builds it, so there is
## no length in the header to measure against — and a bar that sat at nothing for twelve
## megabytes would be saying the download had stalled. The count beside it is the real number
## either way, so the estimate being off shows as a bar that arrives early or crawls at the
## end rather than as a wrong answer. An operation whose archive weighs something else
## carries [code]download_bytes[/code] on its schema entry.
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

## What this row shows and fetches, from the schema entry. See [method setup].
var _label := "Model Folder"
var _url := MODEL_URL
var _bytes := ESTIMATED_DOWNLOAD_BYTES

## Whether the folder holds a folder per model rather than one model's files directly. See
## [method _has_model].
var _many_models := false

## Where the models sit inside the archive, when it keeps them in one folder. What is under
## it lands in the model folder with its arrangement intact, and everything else in the
## archive is left alone. See [method _destination_for].
var _archive_subfolder := ""

## Whether a model's folder is worked out from its file name rather than from where the
## archive put it, for an archive that ships them all in one heap. See
## [method _model_folder_for].
var _folder_from_name := false

## The files this folder has to hold, by name, when what belongs in it is a fixed list
## rather than a model.
##
## Set for a runtime rather than a network: these are named libraries, not a
## [code].param[/code] with a [code].bin[/code] beside it. They are the only things taken out
## of the archive, wherever in it they sit, and the folder counts as filled when all of them
## are there.
var _files := PackedStringArray()

## What this control calls the thing it fetches, and what its button says. A runtime is not
## a model and the lines about it should not say it is.
var _noun := "model"
var _download_label := "Download Latest Model"

## Whether what this folder feeds is one of the ncnn networks, which a build can be missing.
## False for a runtime that has nothing to do with ncnn — see [method _network_built].
var _needs_network := true

## A folder fixed in code, which leaves the path row out entirely. Empty for a control whose
## folder is a setting. See [method setup_fixed].
var _fixed := ""

## Whether the row carries its own Refresh button. Off for a card whose preview follows
## settings on its own, where the button would be a second way to do nothing new.
var _show_refresh := true

var _field: LineEdit
var _browse: Button
var _refresh_button: Button
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


## [param setting] is the whole schema entry, read for what this control can carry per
## operation: [code]label[/code], [code]download_url[/code], [code]download_bytes[/code],
## [code]models_in_folders[/code], [code]archive_subfolder[/code],
## [code]folder_from_file_name[/code] and [code]show_refresh[/code]. Each falls back to the
## value above when the entry says nothing — except the URL, where a key present but empty
## means no archive is published for this model yet.
func setup(operation: IWOperation, property: StringName, fallback := "",
        setting: Dictionary = {}) -> void:
    _operation = operation
    _property = property
    _fallback = fallback
    _read_schema(setting)
    _settle()
    _build()
    refresh()


## The same, for a folder fixed in code rather than held in a setting.
##
## No path row and nothing written back: [param folder] is where the model goes and the only
## place it is looked for. [param setting] carries the keys [method setup] reads.
func setup_fixed(folder: String, setting: Dictionary = {}) -> void:
    _fixed = folder
    _read_schema(setting)
    _build()
    refresh()


func _read_schema(setting: Dictionary) -> void:
    _label = String(setting.get("label", _label))
    _url = String(setting.get("download_url", _url))
    _bytes = int(setting.get("download_bytes", _bytes))
    _many_models = bool(setting.get("models_in_folders", _many_models))
    _archive_subfolder = String(setting.get("archive_subfolder", _archive_subfolder))
    _folder_from_name = bool(setting.get("folder_from_file_name", _folder_from_name))
    _files = PackedStringArray(setting.get("files", _files))
    _noun = String(setting.get("noun", _noun))
    _download_label = String(setting.get("download_label", _download_label))
    _needs_network = bool(setting.get("needs_network", _needs_network))
    _show_refresh = bool(setting.get("show_refresh", _show_refresh))


## What this control calls the thing it fetches, in the lines that mention it.
func _subject() -> String:
    if _noun != "model":
        return _noun
    return "models" if _many_models else "model"


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


## The tree lives in scenes/iw_model_folder.tscn; this fetches it and wires it up.
##
## The two rows the schema can turn off are hidden rather than skipped, and their
## variables left null so everything downstream reads them the way it always has.
func _build() -> void:
    if _download != null:
        return
    _warning = %Warning
    _download = %DownloadButton

    # Hidden for a fixed folder: a path that cannot be edited is one more row saying
    # something the warning below already says when it matters.
    if _fixed.is_empty():
        (%Caption as Label).text = _label
        _field = %Field
        _field.text = _stored()
        _field.text_changed.connect(_on_typed)
        _browse = %Browse
        _browse.pressed.connect(_on_browse)
    else:
        (%PathRow as Control).visible = false

    if _show_refresh:
        _refresh_button = %RefreshButton
        _refresh_button.pressed.connect(func() -> void: refresh_requested.emit())
    else:
        (%RefreshButton as Control).visible = false

    _download.text = _download_label
    if _url.is_empty():
        _download.tooltip_text = "No archive is published for this model yet.\nConvert one yourself and point the folder above at it."
    else:
        _download.tooltip_text = "Fetches the %s and unpacks it into %s.\n\nAround %s. Anything already there under the same name is\noverwritten." % [
                _subject(),
                "the folder above" if _fixed.is_empty() else _fixed,
                String.humanize_size(_bytes)]
    _download.pressed.connect(_on_download)

    # Off until there are bytes to count. Godot turns processing on for any node whose
    # script defines _process, and this one has nothing to do between downloads.
    set_process(false)


## What the setting holds, read at the moment it is asked for rather than cached — the dock
## swaps the settings Resource under this control without rebuilding it.
func _raw() -> String:
    var settings := _operation.get_settings() if _operation != null else null
    return String(settings.get(_property)) if settings != null else ""


## The folder this control is about: the fixed one, or what the setting holds, or the
## fallback while it holds nothing. See [member _fixed] and [member _fallback].
func _stored() -> String:
    if not _fixed.is_empty():
        return _fixed
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
    # The download button is the one thing every arrangement of this control has, so it is
    # what says whether _build has run.
    if _download == null:
        return
    if _field != null and _field.text != _stored():
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
    if _needs_network and not _network_built():
        return "This build has no network to run, so no model would help. See tools/build_ncnn.py."
    var dir := _resolved()
    if dir.is_empty():
        if _url.is_empty():
            return "No folder named. Point this at the folder holding the model."
        return "No folder named. Point this at one and press Download Latest Model."
    if not DirAccess.dir_exists_absolute(dir):
        if _url.is_empty():
            return "%s does not exist yet." % _stored()
        return "%s does not exist yet. Download Latest Model will make it." % _stored()
    if not _has_model(dir):
        return _nothing_here()
    return ""


## What to say about a folder that is there and holds nothing this can load.
##
## Four ways of saying it, because two things change what can be done about it: whether an
## archive is published to fetch, and whether the folder can be pointed somewhere else.
func _nothing_here() -> String:
    var subject := "No %s here." % _subject()
    var pointable := _fixed.is_empty()
    if _url.is_empty():
        if pointable:
            return "%s Point this at a folder holding a .param with a .bin of the same name beside it." % subject
        return "%s Nothing is published to fetch, so it has to be put there by hand." % subject
    if pointable:
        return "%s Press %s, or point this at a folder holding a .param with a .bin of the same name beside it." % [subject, _download_label]
    return "%s Press %s." % [subject, _download_label]


## Whether [param dir] holds what this control is about: every named file, a pair of files,
## or — when the folder holds a folder per model — at least one folder holding a pair.
func _has_model(dir: String) -> bool:
    if not _files.is_empty():
        for name in _files:
            if not FileAccess.file_exists(dir.path_join(name)):
                return false
        return true
    if not _many_models:
        return not _model_in(dir).is_empty()
    for folder in DirAccess.get_directories_at(dir):
        if not _model_in(dir.path_join(folder)).is_empty():
            return true
    return false


## Whether this build has the network wrappers at all.
##
## Asked of [ClassDB] rather than of any one operation, so this control needs no reference
## to the layers that use it. One class stands for all of them: every ncnn wrapper is
## compiled in or left out together — see [code]register_types.cpp[/code].
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
    if _download == null:
        return
    var live := _interactive and not _busy
    if _field != null:
        _field.editable = live
        _browse.disabled = not live
    if _refresh_button != null:
        _refresh_button.disabled = not live
    _download.disabled = not live or _url.is_empty() \
            or (_needs_network and not _network_built())
    _download.text = "Downloading..." if _busy else _download_label


# --- Fetching the model -------------------------------------------------

func _on_download() -> void:
    if _busy or _url.is_empty():
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
    _tell(0.0, 0.0, "Connecting to %s" % _host())

    if _http == null:
        _http = HTTPRequest.new()
        # Off the main thread, so a slow connection does not make the dock feel stuck. The
        # signal still arrives on the main thread, which is where everything after it runs.
        _http.use_threads = true
        _http.request_completed.connect(_on_downloaded)
        add_child(_http)
    _http.download_file = dir.path_join(ZIP_NAME)

    var error := _http.request(_url)
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
    var guessed := clampf(float(got) / float(_bytes), 0.0, ESTIMATE_CEILING)
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
        _done("%s answered %d rather than handing over the file." % [_host(), code], false)
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
        relative = _destination_for(relative)
        if relative.is_empty():
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
    # folder it is given — so wherever they landed, they come up to the top. Not needed for a
    # folder per model, where _destination_for has already put every file where it belongs.
    var lifted := "" if _many_models else _lift_model()
    _scrub(zip)
    _tell(1.0, 1.0, "Done")

    if not _has_model(_target_dir):
        _done("The archive came down and unpacked, but does not hold the whole %s."
                % _subject(), false)
        return
    var where := _stored() if lifted.is_empty() else "%s, %s" % [_stored(), lifted]
    _done("%s ready in %s." % [_subject().capitalize(), where], true)


## Where an entry out of the archive belongs under the model folder, or empty to leave it
## out. [param relative] has already had any single top-level folder taken off it.
##
## Three ways round, because the archives are not arranged alike:
##
## [b]An archive with a models folder of its own[/b] has everything under it copied across as
## it stands, and everything outside it dropped. The folder names are the archive's.
##
## [b]An archive that ships its models in one heap[/b] keeps only the model files and works
## out a folder for each from its name, since there is no other record of where it belongs.
##
## [b]Anything else[/b] is taken as it comes, which is right for an archive holding one model
## and nothing else worth refusing.
func _destination_for(relative: String) -> String:
    if not _files.is_empty():
        var wanted := relative.get_file()
        return wanted if _files.has(wanted) else ""
    if not _archive_subfolder.is_empty():
        var prefix := _archive_subfolder + "/"
        return relative.substr(prefix.length()) if relative.begins_with(prefix) else ""
    if not _folder_from_name:
        return relative
    var file := relative.get_file()
    var extension := file.get_extension().to_lower()
    if extension != "param" and extension != "bin":
        return ""
    return _model_folder_for(file.get_basename()).path_join(file)


## The folder a model file belongs in, which is its name with any trailing ratio taken off.
##
## [code]realesr-animevideov3-x2[/code] goes in [code]realesr-animevideov3[/code] beside its
## other two ratios, and [code]realesrgan-x4plus[/code] — whose 4 is part of the name rather
## than a ratio on the end — names its own folder.
static func _model_folder_for(base: String) -> String:
    var cut := base.rfind("-x")
    if cut < 0:
        return base
    return base.substr(0, cut) if base.substr(cut + 2).is_valid_int() else base


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


## The server the archive comes from, for the lines that name where they are talking to.
func _host() -> String:
    var host := _url.get_slice("/", 2)
    return host if not host.is_empty() else "the server"


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
