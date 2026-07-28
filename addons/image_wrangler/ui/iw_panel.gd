@tool
extends VBoxContainer

## The Image Wrangler main screen: pick images, tweak an operation, write results.

const SettingsBuilder := preload("res://addons/image_wrangler/ui/iw_settings_builder.gd")
const PreviewView := preload("res://addons/image_wrangler/ui/iw_preview_view.gd")
const IslandPicker := preload("res://addons/image_wrangler/ui/iw_island_picker.gd")
const ColorList := preload("res://addons/image_wrangler/ui/iw_color_list.gd")
const PolygonList := preload("res://addons/image_wrangler/ui/iw_polygon_list.gd")
const SettingsIO := preload("res://addons/image_wrangler/core/iw_settings_io.gd")
const StackView := preload("res://addons/image_wrangler/ui/iw_stack_view.gd")
const HistoryView := preload("res://addons/image_wrangler/ui/iw_history_view.gd")

## Every [IWStackOperation] the stack can hold, in the order the dropdown offers them.
## Add new stack operations here.
const OPERATION_SCRIPTS := [
    "res://addons/image_wrangler/core/denoise.gd",
    "res://addons/image_wrangler/core/smooth_blocks.gd",
    "res://addons/image_wrangler/core/smooth_color.gd",
    "res://addons/image_wrangler/core/remove_background.gd",
    "res://addons/image_wrangler/core/remove_crevice.gd",
    "res://addons/image_wrangler/core/refine_edges.gd",
    "res://addons/image_wrangler/core/island_picker_op.gd",
    "res://addons/image_wrangler/core/polygon_edit_op.gd",
    "res://addons/image_wrangler/core/remove_lines.gd",
    "res://addons/image_wrangler/core/edge_cleanup.gd",
]

## What a fresh image's stack starts as.
##
## [b]The one operation that is always the answer.[/b] Every other stage is a response to
## something a particular image did — a nook the flood could not get into, an island the
## border could not reach, an edge that came back harder than it went in — and an image
## that did none of those things does not want the stage that fixes it. A default stack
## that guessed at all of them started every image carrying work nobody had asked for,
## and made the form a list of things to switch off rather than a list of things to
## reach for.
##
## It also makes the default honest about the one thing this addon does. Add what the
## image turns out to need; the dropdown is right there, and the order the rest
## want to go in is on their own entries.
const DEFAULT_STACK := [
    "res://addons/image_wrangler/core/remove_background.gd",
]

## The file operation, which is not a stack operation and never will be: it does not
## touch pixels, and its settings describe the batch rather than any one image.
const RENAME_SCRIPT := "res://addons/image_wrangler/core/rename.gd"

## Extensions [method Image.load_from_file] can read.
const SUPPORTED_EXTENSIONS := ["png", "jpg", "jpeg", "bmp", "tga", "webp"]

## Above this size the preview stops following settings changes, since every
## tweak would otherwise re-run the whole image and stall the editor. Refresh
## still runs it on demand.
##
## Judged from the image rather than offered as a switch: the only reason to turn
## automatic preview off is that it has become too slow, and the dock can see that
## for itself.
const AUTO_PREVIEW_PIXEL_LIMIT := 4_194_304

## Width of the Original fade slider. Enough to aim with, short enough that the
## toolbar does not pin the preview column open.
const ORIGINAL_FADE_WIDTH := 90

const ORIGINAL_FADE_TOOLTIP := """Fades the source image in over the result.

At 0 you see the result, at 100 the untouched source, and in between both
at once — which is how you judge whether an edge was eaten or a fringe
left behind, since the two are then in the same place at the same time."""

const THREADING_TOOLTIP := """Runs the preview on a worker thread instead of on the main one.

With it on, the editor stays responsive while an image is being worked
and a run already in flight can be abandoned the moment a setting
changes. With it off, every run blocks the editor until it finishes —
slower to work with, but there is one thread touching the image, which
is what you want while judging whether a result is the operation's
doing or the threading's.

Off for now. Processing files is unaffected either way; only the
preview is threaded."""

## Whether saving one of this addon's own scripts rebuilds the interface by itself.
##
## On, because the alternative is remembering to press the shortcut — and an edit that
## appears to have done nothing, when what actually happened is that nothing built it a
## second time, is a confusing thing to debug. Set false to rebuild only on demand.
const AUTO_REBUILD := true

## Seconds to let the editor finish reloading before building against the new code.
##
## The signal says a reload is coming, not that it has happened: the editor collects the
## changed resources and swaps them on the next idle. Rebuilding inside the signal would
## run the old code one more time, which looks exactly like the feature not working.
const REBUILD_SETTLE := 0.3

## Where a script has to live for a change to it to mean anything here. Everything else
## the editor reloads — another addon, a script in the project proper — is none of this
## dock's business.
const ADDON_ROOT := "res://addons/image_wrangler/"

## Settings edits arrive in bursts while a slider is dragged; collapse them.
const PREVIEW_DEBOUNCE := 0.15

## How close a zoom has to be to a ladder rung to count as that rung rather than
## as a value of its own. Comfortably under the smallest gap in the ladder.
const _ZOOM_MATCH := 0.01

## Longer than the preview debounce on purpose. The preview has to feel live; a
## disk write must not happen seven times a second while a slider is dragged.
const AUTOSAVE_DEBOUNCE := 0.75

## Shared by the Suffix field and its label, so hovering either explains the
## setting — and so the warning in it cannot end up on only one of them.
##
## Long for a tooltip, because a blank suffix is the one setting here that can
## destroy the files being worked on, and the confirmation it leads to does not
## say so.
const SUFFIX_TOOLTIP := """Goes on the end of the output name, before the extension —
flower.png with "_nobg" becomes flower_nobg.png.

Process Current Only just suggests it, so you can still rename the
file in the Save As dialog. Process All applies it to every file
without asking again, which makes the suffix the only thing keeping
the results apart from the sources.

So take care when it is blank: each output then keeps its source's
own name, and pointing Process All at the folder the sources are in
will overwrite the originals in place. You are asked to confirm, but
the prompt only says those files already exist — not that they are
the images you are processing. There is no undo.

Anything that rewrites pixels is saved as PNG. Rename copies the
file untouched, so it keeps whatever format it already had."""

## What the Process buttons will run: the stack, or the file operation.
##
## Rename is not a stage and cannot be one — it does not touch pixels, and its
## settings describe the batch rather than any one image — so it lives beside the
## stack rather than in it, and the two are switched between.
## Tab order, and the tab index is the mode. History sits beside Operations rather than
## after Rename because it is about the stack: everything it lists is an edit to one, and
## a rename scheme has no history because it belongs to the batch rather than to an image.
##
## For everything that follows from the mode, History [i]is[/i] image mode — it previews,
## it autosaves, it processes pixels. The tests below are written against [constant
## Mode.RENAME] rather than for [constant Mode.IMAGE] for that reason: a new tab on the
## image side should not have to find every one of them.
enum Mode { IMAGE, HISTORY, RENAME }

var _mode := Mode.IMAGE

## The file operation, held for the session. One set of settings, no sidecar.
var _rename: IWOperation
var _sources: PackedStringArray = PackedStringArray()
var _source_image: Image
var _result_image: Image

## The worker running a preview, or null when nothing is in flight.
##
## One at a time. [Thread] has to be joined before it can be replaced and joining
## blocks, so a second one would reintroduce exactly the stall the thread exists
## to remove — [member _preview_pending] queues the next run instead.
var _preview_thread: Thread

## Whether a run is in flight, in either mode.
##
## [member _preview_thread] used to answer this on its own. With threading off there is
## no thread to point at but there is still a run in progress — it is sitting between
## two stages, and the editor is live enough in that gap for the debounce to fire and
## ask for another.
var _preview_running := false

## Whether a preview is allowed to leave the main thread.
##
## Read once per run, when the run starts, so flipping it never has to reach into a
## worker that is already going — that one finishes the way it began and the next
## one picks up the new answer.
var _threading_enabled := false

## Whether something asked for a preview while one was already running, which also
## means whatever comes back from that run is out of date.
var _preview_pending := false

## Set while the dock is leaving the tree, and checked by everything a run reports
## back through.
##
## A worker reports by deferral, so its calls can still be sitting in the message queue
## when the dock is pulled out from under them. The queue drops a call whose object has
## been freed, but between leaving the tree and being freed the dock is still a valid
## object holding controls that are on their way out — and that is the window these
## guards close.
var _shutting_down := false

## The operation the worker is running, kept so it can be told to stop.
##
## A run that has been superseded is producing an answer nobody will look at, so
## there is no reason to let it finish — cancelling it frees the core and gets the
## replacement started sooner.
var _preview_worker_op: IWOperation
var _suffix_is_default := true
var _pending_outputs: Dictionary = {}

## The stack saved for each source path, as the ordered list
## [code][{id, enabled, settings}][/code] the sidecar stores.
##
## An entry appears the first time an image is selected or processed: loaded from its
## JSON sidecar when it has one, and the default stack when it does not. Nothing is
## inherited from the image selected before it.
##
## While the dock is open this is the source of truth — the sidecar is read once per
## path and never re-read, so a half-written file or an external edit landing mid-drag
## cannot clobber live state.
var _stacks_by_path: Dictionary = {}

## Which stack entries are folded, keyed by the entry's uid.
##
## Keyed by uid rather than by operation id, because the same operation may appear
## twice and folding one must not fold the other. Kept for the session and not written
## to a sidecar: a fold is about what you are working on this afternoon, not about the
## image.
var _fold_state: Dictionary = {}

## Set while the form is being repointed at another image's settings. Every
## change handler early-returns on it.
##
## The no-signal setters in [SettingsBuilder] should make this unnecessary, but
## the cost of one leaking through is no longer a stray preview — it is writing
## one image's values into another image's sidecar at the moment of the swap. And
## [ColorPickerButton] has no no-signal setter at all, so for the swatch this is
## the only defence.
var _refreshing := false

## Whether a rebuild is already waiting out [constant REBUILD_SETTLE].
##
## One save can reload a dozen scripts and the signal arrives per batch, so without this
## a busy save would queue a rebuild for each of them and the dock would be taken apart
## and put back together several times over.
var _rebuild_queued := false

## Path the pending autosave belongs to, captured when it was scheduled: the
## selection can move before the timer fires.
var _autosave_path := ""

## Paths whose sidecar could not be written, so the failure is reported once
## rather than on every tick of a slider drag.
var _autosave_failures := {}

var _file_list: ItemList
var _preview: PreviewView

## Every picker or drawing control the stack's forms built, in stack order.
##
## Flat and rebuilt whenever the stack changes, because there is no longer one of
## each: two Island Pickers in the stack are two independent lists, and both have a
## Pick button.
var _pick_controls: Array[Control] = []

## Whichever control currently owns the preview crosshair, or null.
##
## There is one preview and any number of controls that would like to be told about a
## click on it, so a click would otherwise be ambiguous. Arming one disarms the rest,
## and this is what the click is then delivered to.
var _pick_target: Control

## The control whose selection the overlay highlights, or null.
##
## The preview takes one flat list of markers and one of regions, so the selections of
## several controls have to be merged into a single index. Only one control's
## selection is shown — the last one touched — and it is offset by everything drawn
## before it.
var _overlay_owner: Control
var _status_label: Label
var _detail_label: Label
var _stack_view: Control
var _history_view: Control

## One [IWHistory] per image path, made when the image is first shown.
##
## Session only, and deliberately: what an image's settings are belongs on disk, how they
## got that way does not. Keyed by path like [member _stacks_by_path], and never pruned —
## an image taken out of the list and put back has its edits waiting, which is what a
## user who removed a row by accident expects.
var _history_by_path: Dictionary = {}

## Operation id to display name, filled on first use. Built once because naming a stage
## otherwise means instantiating every operation script, and a history row asks per row.
var _operation_names: Dictionary = {}

## The current image's stack as it stood after the last recorded edit, encoded and
## stringified.
##
## Compared against on every change to answer "did anything actually move", which is what
## makes the two funnels below safe to hook: they fire for edits that changed nothing, and
## a history full of entries that did nothing would be worse than no history.
var _shadow_text := ""

## Set while an undo or a redo is putting a state back, so the rebuild that causes is not
## recorded as a fresh edit.
var _applying_history := false

## What to call the next recorded edit, for the ones the diff would describe badly.
var _pending_label := ""

## The Operations / History / Rename tabs. Tab order is [enum Mode] order, so the index
## the container reports is the mode itself.
var _modes: TabContainer

## Rename's form, built into its own box and hidden while the stack is showing.
var _rename_box: VBoxContainer
## How much of the source image is faded over the result, 0 to 100.
var _original_fade: HSlider
var _zoom_select: OptionButton
var _zoom_entry: LineEdit
var _thread_toggle: CheckBox
var _refresh_button: Button
var _remove_button: Button
var _clear_button: Button
var _suffix_edit: LineEdit
var _process_selected_button: Button
var _process_all_button: Button
var _debounce: Timer
var _autosave: Timer
var _open_dialog: FileDialog
var _output_dialog: FileDialog
var _save_dialog: FileDialog

## Which source a pending Save As belongs to, held between opening the dialog
## and the user choosing a name.
var _save_source := ""
var _overwrite_dialog: ConfirmationDialog
var _removal_dialog: ConfirmationDialog
var _reset_dialog: ConfirmationDialog
var _stack_save_dialog: FileDialog
var _stack_load_dialog: FileDialog

## Sources whose originals may be deleted, mapped to the copy that replaced them.
## Filled during a run and acted on only after the user confirms and every copy
## has been proved identical to its source.
var _pending_removals: Dictionary = {}


func _enter_tree() -> void:
    # Cleared rather than assumed false: the dock can be taken out of the tree and put
    # back, and the flag would otherwise survive as a permanent mute.
    _shutting_down = false

    # Connected here rather than in [method _ready], so it is paired with the disconnect
    # in [method _exit_tree] and a dock put back into the tree is listening again.
    var filesystem := EditorInterface.get_resource_filesystem()
    if filesystem != null and not filesystem.resources_reload.is_connected(_on_resources_reload):
        filesystem.resources_reload.connect(_on_resources_reload)


func _ready() -> void:
    # Only a floor, so the splitters between the columns stay freely draggable.
    custom_minimum_size = Vector2(0, 240)
    # The forms are built into containers the layout owns, so the layout goes first.
    _build_ui()
    _build_rename()
    _apply_stack_for("")
    _select_mode(Mode.IMAGE)
    _refresh_file_list()
    _update_controls()


## The dock's keyboard shortcuts: Escape and Backspace close and unwind a drawn
## region in progress.
##
## Scoped to the dock rather than bound globally: they only fire while the panel
## is on screen and the pointer is inside it, so these keys stay free everywhere
## else in the editor. Being unhandled input, they also never steal a keystroke
## from a focused text field.
##
## Escape and Backspace are further gated on a region actually being drawn, so
## they do nothing at all the rest of the time — Backspace especially, which has
## an obvious meaning elsewhere and must not be swallowed here.
##
## Ctrl+Shift+R rebuilds the interface, which is a development affordance rather than
## a feature: see [method _rebuild_ui]. It takes a modifier so it cannot be hit by
## accident, and being scoped to the dock like the rest, it leaves the combination free
## everywhere else in the editor.
func _unhandled_key_input(event: InputEvent) -> void:
    if _preview == null or not is_visible_in_tree():
        return
    var key := event as InputEventKey
    if key == null or not key.pressed or key.echo:
        return
    if not get_global_rect().has_point(get_global_mouse_position()):
        return

    if key.keycode == KEY_R and key.ctrl_pressed and key.shift_pressed \
            and not key.alt_pressed and not key.meta_pressed:
        # Before the rebuild rather than after it: what this is called on is about to be
        # taken apart, and marking the key handled is not something to leave until then.
        accept_event()
        _rebuild_ui()
        return

    if key.ctrl_pressed or key.alt_pressed or key.shift_pressed or key.meta_pressed:
        return

    var drawing := _drawing_list()
    if drawing == null or drawing.draft_index() < 0:
        return
    if key.keycode == KEY_ESCAPE:
        _finish_polygon()
        accept_event()
    elif key.keycode == KEY_BACKSPACE:
        drawing.undo_vertex()
        _update_overlays()
        accept_event()


## A pending write must not die with the dock: this runs on plugin disable and on
## editor shutdown. It deliberately touches only the settings store and the
## codec, nothing that needs the panel to still be in the tree.
##
## A running worker has to be joined here as well. It holds nothing of the dock's
## but its own copy of the settings, so waiting is safe — and not waiting means
## letting the editor tear down a node a live thread is about to call back into.
## The wait is bounded by whatever one image takes.
func _exit_tree() -> void:
    # Before anything else: the join below pumps no messages, but a worker that
    # finishes during it will have queued its report by the time this returns.
    _shutting_down = true

    var filesystem := EditorInterface.get_resource_filesystem()
    if filesystem != null and filesystem.resources_reload.is_connected(_on_resources_reload):
        filesystem.resources_reload.disconnect(_on_resources_reload)

    _flush_autosave()
    _preview_pending = false
    # Asked to stop before being waited on, so the wait is however long the current
    # pass has left rather than however long the whole image takes.
    if _preview_worker_op != null:
        _preview_worker_op.cancelled = true
    if _preview_thread != null:
        _preview_thread.wait_to_finish()
        _preview_thread = null
    _preview_worker_op = null
    # An unthreaded run cannot be waited on the way a thread can — it is parked on a
    # frame that has not come yet. Cancelling it above is what stops it: it resumes,
    # finds the flag at its next checkpoint and drops out without reporting. This
    # clears the way for the next run should the dock come back.
    _preview_running = false


## Builds the file operation and its form. One instance for the session, since a
## rename scheme describes the batch rather than any one image.
##
## The operation is made only when there is not one already, so that rebuilding the
## dock rebuilds the form without resetting what has been dialled into it — the whole
## point of the instance lasting the session.
func _build_rename() -> void:
    if _rename == null:
        var script: GDScript = load(RENAME_SCRIPT)
        if script == null:
            push_error("Image Wrangler: could not load operation script at %s" % RENAME_SCRIPT)
            return
        _rename = script.new()
    SettingsBuilder.build(_rename, _rename_box, _on_setting_changed, _fold_state, "rename")


## Rebuilds the dock when one of this addon's scripts has been reloaded.
##
## [param resources] is everything the editor is about to swap, which is how this can
## ignore the rest of the project — and, more to the point, ignore the sidecar the dock
## writes itself. A rebuild flushes a pending autosave, so a rule that fired on any file
## at all would have the dock rebuilding in response to its own writing.
##
## Only the arrival is handled here. The rebuild waits, because at this moment the new
## code has not been loaded yet — see [constant REBUILD_SETTLE].
func _on_resources_reload(resources: PackedStringArray) -> void:
    if not AUTO_REBUILD or _rebuild_queued or _shutting_down or not is_inside_tree():
        return

    var ours := false
    for path in resources:
        if path.begins_with(ADDON_ROOT) and path.ends_with(".gd"):
            ours = true
            break
    if not ours:
        return

    # A half-drawn region lives on the control a rebuild throws away. Losing one to a
    # file being saved in another window is not a trade worth making silently, so the
    # rebuild is left to the shortcut and the line below says so.
    var drawing := _drawing_list()
    if drawing != null and drawing.draft_index() >= 0:
        _set_status("Scripts changed. Finish the region, then Ctrl+Shift+R to rebuild.")
        return

    _rebuild_queued = true
    # A [SceneTreeTimer] rather than one of the dock's own, which are children and would
    # be freed by the very rebuild they are waiting to start. Connected rather than
    # awaited, because this script is itself among the ones about to be reloaded and a
    # suspended coroutine belongs to the version being replaced.
    get_tree().create_timer(REBUILD_SETTLE).timeout.connect(_on_rebuild_settled)


func _on_rebuild_settled() -> void:
    _rebuild_queued = false
    # The wait is long enough for the dock to have been taken out from under it, or for
    # the plugin to have been switched off entirely.
    if _shutting_down or not is_inside_tree():
        return
    _rebuild_ui()
    _set_status("Scripts reloaded. Interface rebuilt.")


## Throws the interface away and builds it again, keeping the session.
##
## For working on the layout. Saving a [code]@tool[/code] script swaps the code under
## the instances already in the tree, but re-runs neither [method _init] nor
## [method _ready] — so a changed method body or constant takes effect at its next call,
## while every change to how a control is *made* stays invisible. Which toolbar
## something goes on, what its tooltip says, whether it exists at all: none of that can
## appear until something builds it a second time. Toggling the plugin does that and
## takes the session with it. This does it and keeps it.
##
## What survives does so because it lives on the dock rather than in a control: the
## source list, each image's stack and fold state, the image being looked at, the file
## operation. What is read off the controls here — the selection, the zoom, the mode, a
## typed suffix — is put back afterwards. Everything else is built fresh, which is the
## entire point of the exercise.
func _rebuild_ui() -> void:
    # A pending sidecar write belongs to the stack about to be taken down, and the flush
    # resolves it against the current mode, so it goes before any of this.
    _flush_autosave()

    # A run in flight reports into controls that are about to be freed. Cancelled and
    # joined exactly as [method _exit_tree] does it, and for the same reason — the wait
    # is however long the current pass has left. An unthreaded run cannot be waited on,
    # but the cancel reaches it at its next checkpoint and what it reports then lands on
    # the rebuilt controls harmlessly.
    _preview_pending = false
    if _preview_worker_op != null:
        _preview_worker_op.cancelled = true
    if _preview_thread != null:
        _preview_thread.wait_to_finish()
        _preview_thread = null
    _preview_worker_op = null
    _preview_running = false

    var path := _current_path()
    var selected := _selected_index()
    var mode := _mode
    var suffix := _suffix_edit.text
    var fade := _original_fade.value
    var zoom := _preview.get_zoom()
    var threading := _threading_enabled
    # Back into the store the rebuild reads it out of, so the new form comes up pointed
    # at the same operation instances rather than at fresh ones carrying defaults.
    _store_stack(path)

    # Removed before being freed, not merely queued: a queue_free alone leaves the old
    # columns in the tree for the rest of the frame, laid out alongside the new ones.
    for child in get_children():
        remove_child(child)
        child.queue_free()
    _forget_controls()

    _build_ui()
    _build_rename()

    _threading_enabled = threading
    _thread_toggle.set_pressed_no_signal(threading)
    _apply_stack_for(path)
    _refresh_file_list()
    if selected >= 0 and selected < _file_list.item_count:
        _file_list.select(selected)
    _suffix_edit.text = suffix
    _original_fade.set_value_no_signal(fade)
    _preview.original_fade = fade * 0.01

    # Held across the mode switch, which clears it: the result on screen a moment ago
    # still describes this image, and dropping it would blank the preview until the
    # rerun below lands.
    var result := _result_image
    _select_mode(mode)
    _result_image = result
    _update_preview_texture()
    # Deferred, unlike everything above it: the new preview has no size until the
    # containers have laid out, and a zoom worked out against a viewport of nothing
    # lands the image somewhere it was never asked to go.
    _preview.set_zoom.call_deferred(zoom)

    _update_overlays()
    _update_controls()
    _update_detail_label()
    _set_status("Interface rebuilt.")


## Drops every reference to a control the build made.
##
## Between the teardown and the rebuild each of these names a freed object, and the
## handful of guards that check for null are written expecting exactly that.
func _forget_controls() -> void:
    _pick_controls.clear()
    _pick_target = null
    _overlay_owner = null
    _file_list = null
    _preview = null
    _status_label = null
    _detail_label = null
    _stack_view = null
    _modes = null
    _rename_box = null
    _original_fade = null
    _zoom_select = null
    _zoom_entry = null
    _thread_toggle = null
    _refresh_button = null
    _remove_button = null
    _clear_button = null
    _suffix_edit = null
    _process_selected_button = null
    _process_all_button = null
    _debounce = null
    _autosave = null
    _open_dialog = null
    _output_dialog = null
    _save_dialog = null
    _overwrite_dialog = null
    _removal_dialog = null


# --- Layout -------------------------------------------------------------

func _build_ui() -> void:
    add_theme_constant_override("separation", 4)

    var columns := HSplitContainer.new()
    columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
    add_child(columns)

    columns.add_child(_build_source_column())

    var right_split := HSplitContainer.new()
    right_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    columns.add_child(right_split)
    right_split.add_child(_build_preview_column())
    right_split.add_child(_build_operation_column())

    _build_dialogs()

    _debounce = Timer.new()
    _debounce.one_shot = true
    _debounce.wait_time = PREVIEW_DEBOUNCE
    _debounce.timeout.connect(_run_preview)
    add_child(_debounce)

    _autosave = Timer.new()
    _autosave.one_shot = true
    _autosave.wait_time = AUTOSAVE_DEBOUNCE
    _autosave.timeout.connect(_flush_autosave)
    add_child(_autosave)


## Takes effect at the next run. A worker already going is left alone — see
## [member _threading_enabled].
func _on_threading_toggled(pressed: bool) -> void:
    _threading_enabled = pressed


func _build_source_column() -> Control:
    var column := VBoxContainer.new()
    column.custom_minimum_size = Vector2(140, 0)

    var header := HBoxContainer.new()
    column.add_child(header)

    var title := Label.new()
    title.text = "Images"
    title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    header.add_child(title)

    var add_button := Button.new()
    add_button.text = "Add"
    add_button.tooltip_text = "Add image files."
    add_button.pressed.connect(func() -> void: _open_dialog.popup_centered_ratio(0.6))
    header.add_child(add_button)

    _remove_button = Button.new()
    _remove_button.text = "Remove"
    _remove_button.tooltip_text = "Remove the selected image from the list. The file is not touched."
    _remove_button.pressed.connect(_on_remove_pressed)
    header.add_child(_remove_button)

    _clear_button = Button.new()
    _clear_button.text = "Clear"
    _clear_button.tooltip_text = "Remove every image from the list. The files are not touched."
    _clear_button.pressed.connect(_on_clear_pressed)
    header.add_child(_clear_button)

    _file_list = ItemList.new()
    _file_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _file_list.allow_reselect = true
    _file_list.item_selected.connect(_on_file_selected)
    column.add_child(_file_list)

    var hint := Label.new()
    hint.text = "Drag images here from the FileSystem dock."
    hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    hint.modulate = Color(1, 1, 1, 0.6)
    column.add_child(hint)

    return column


func _build_preview_column() -> Control:
    var column := VBoxContainer.new()
    column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    column.custom_minimum_size = Vector2(140, 0)

    var toolbar := HBoxContainer.new()
    column.add_child(toolbar)

    # Labels are kept short on purpose: a container's minimum width comes from
    # its children, so a chatty toolbar would pin this column open and stop the
    # splitters from moving.
    var original_label := Label.new()
    original_label.text = "Original"
    original_label.tooltip_text = ORIGINAL_FADE_TOOLTIP
    original_label.mouse_filter = Control.MOUSE_FILTER_PASS
    toolbar.add_child(original_label)

    # A slider rather than the toggle this was, because the question being asked
    # of the preview is almost never "which of these two" — it is "how much of the
    # edge did I just eat", and that is a question about the difference between
    # them. Fading one over the other puts the two in the same place at the same
    # time, where a toggle makes you hold one in your head while looking at the
    # other.
    _original_fade = HSlider.new()
    _original_fade.min_value = 0.0
    _original_fade.max_value = 100.0
    _original_fade.step = 1.0
    _original_fade.value = 0.0
    _original_fade.custom_minimum_size = Vector2(ORIGINAL_FADE_WIDTH, 0)
    _original_fade.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    _original_fade.tooltip_text = ORIGINAL_FADE_TOOLTIP
    _original_fade.value_changed.connect(_on_original_fade_changed)
    toolbar.add_child(_original_fade)

    # The one long label on this toolbar, and it does widen the column's minimum —
    # but this is a switch you want in sight while judging a result, not one to go
    # hunting for, and it is spelled out rather than abbreviated because what it
    # changes is not something to have to guess at.
    _thread_toggle = CheckBox.new()
    _thread_toggle.text = "Enable Threading"
    _thread_toggle.tooltip_text = THREADING_TOOLTIP
    _thread_toggle.button_pressed = _threading_enabled
    _thread_toggle.toggled.connect(_on_threading_toggled)
    toolbar.add_child(_thread_toggle)

    var spacer := Control.new()
    spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    toolbar.add_child(spacer)

    _refresh_button = Button.new()
    _refresh_button.text = "Refresh"
    _refresh_button.tooltip_text = "Re-run the operation on the selected image."
    _refresh_button.pressed.connect(_run_preview)
    toolbar.add_child(_refresh_button)

    _preview = PreviewView.new()
    _preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _preview.pixel_picked.connect(_on_pixel_picked)
    _preview.region_picked.connect(_on_region_picked)
    _preview.pick_cancelled.connect(_on_pick_cancelled)
    _preview.vertex_dragged.connect(_on_vertex_dragged)
    _preview.vertex_drag_ended.connect(_on_vertex_drag_ended)
    _preview.zoom_changed.connect(_on_zoom_changed)
    column.add_child(_preview)

    column.add_child(_build_status_row())

    return column


## The bar under the viewport, Photoshop-style: zoom on the left, status text
## filling the middle, image size hard right. It belongs to the image, so it
## spans the viewport rather than the whole dock.
func _build_status_row() -> Control:
    var row := HBoxContainer.new()

    # The zoom controls keep a zero separation of their own so the buttons stay
    # flush against the field, while the outer row still spaces them off the
    # status text.
    var zoom := HBoxContainer.new()
    zoom.add_theme_constant_override("separation", 0)
    row.add_child(zoom)

    var zoom_out_button := Button.new()
    zoom_out_button.text = "-"
    zoom_out_button.tooltip_text = "Zoom out one step."
    zoom_out_button.pressed.connect(func() -> void: _preview.zoom_out())
    zoom.add_child(zoom_out_button)

    _zoom_select = OptionButton.new()
    _zoom_select.custom_minimum_size = Vector2(76, 0)
    _zoom_select.tooltip_text = "Zoom level. The buttons, the wheel and this list all step through the same\nstops. The wheel zooms towards the pixel under the cursor.\nRight-click to type an exact value instead.\nFit can land between stops; such a value is shown here too, until you\nleave it. Drag to pan — while a tool is active, use middle or Ctrl+left."
    _zoom_select.item_selected.connect(_on_zoom_selected)
    # The signal fires ahead of OptionButton's own handling, so accepting the
    # event here is what stops a right-click also opening the popup.
    _zoom_select.gui_input.connect(_on_zoom_select_input)
    zoom.add_child(_zoom_select)

    # Shares the slot with the dropdown; only ever one of the two is visible.
    _zoom_entry = LineEdit.new()
    _zoom_entry.custom_minimum_size = _zoom_select.custom_minimum_size
    _zoom_entry.alignment = HORIZONTAL_ALIGNMENT_CENTER
    _zoom_entry.tooltip_text = "Type a zoom from 1 to 1000. Enter accepts, Escape cancels."
    _zoom_entry.hide()
    _zoom_entry.text_submitted.connect(_commit_zoom_entry)
    _zoom_entry.focus_exited.connect(func() -> void: _commit_zoom_entry(_zoom_entry.text))
    _zoom_entry.gui_input.connect(_on_zoom_entry_input)
    zoom.add_child(_zoom_entry)

    _refresh_zoom_items(100.0)

    var zoom_in_button := Button.new()
    zoom_in_button.text = "+"
    zoom_in_button.tooltip_text = "Zoom in one step."
    zoom_in_button.pressed.connect(func() -> void: _preview.zoom_in())
    zoom.add_child(zoom_in_button)

    var fit_button := Button.new()
    fit_button.text = "Fit"
    fit_button.tooltip_text = "Zoom so the image fills the frame, whichever axis runs out first."
    fit_button.pressed.connect(func() -> void: _preview.fit_to_view())
    zoom.add_child(fit_button)

    # Messages here name files and can run long. Ellipsising, and letting the
    # label soak up the free space rather than demand it, stops a status message
    # from setting a floor under the preview column's width.
    _status_label = Label.new()
    _status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
    _status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _set_status("No image selected.")
    row.add_child(_status_label)

    _detail_label = Label.new()
    _detail_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
    _detail_label.modulate = Color(1, 1, 1, 0.6)
    row.add_child(_detail_label)

    return row


func _build_operation_column() -> Control:
    var column := VBoxContainer.new()
    column.custom_minimum_size = Vector2(220, 0)

    # Tabs rather than toggles, because the two are not settings of one thing: one
    # rewrites pixels and the other rewrites names, and only one of them is ever what
    # a Process button is about to do. A tab says "you are in here" in a way two
    # pressed-looking buttons do not.
    _modes = TabContainer.new()
    _modes.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _modes.tab_changed.connect(_on_tab_changed)
    column.add_child(_modes)

    # Each tab gets its own scroll, so switching does not carry the other one's
    # scroll position across.
    var stack_page := ScrollContainer.new()
    # The tab strip takes its label from the node's name.
    stack_page.name = "Operations"
    stack_page.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    _modes.add_child(stack_page)

    _stack_view = StackView.new()
    _stack_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _stack_view.operation_scripts = OPERATION_SCRIPTS
    _stack_view.fold_state = _fold_state
    _stack_view.form_builder = _build_entry_form
    _stack_view.stack_changed.connect(_on_stack_changed)
    _stack_view.setting_changed.connect(_on_setting_changed)
    _stack_view.entries_rebuilt.connect(_on_entries_rebuilt)
    _stack_view.copy_requested.connect(_on_copy_stack)
    _stack_view.paste_requested.connect(_on_paste_stack)
    _stack_view.save_requested.connect(_on_save_stack)
    _stack_view.load_requested.connect(_on_load_stack)
    _stack_view.reset_requested.connect(_on_reset_stack)
    stack_page.add_child(_stack_view)

    # No scroll of its own: the list inside it scrolls, and nesting the two would give
    # the tab a scrollbar that moved a list with a scrollbar in it.
    _history_view = HistoryView.new()
    _history_view.name = "History"
    _history_view.revert_requested.connect(_on_history_revert)
    _modes.add_child(_history_view)

    var rename_page := ScrollContainer.new()
    rename_page.name = "Rename"
    rename_page.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    _modes.add_child(rename_page)

    _rename_box = VBoxContainer.new()
    _rename_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    rename_page.add_child(_rename_box)

    _modes.set_tab_tooltip(Mode.IMAGE, "Build a stack of operations that rewrite the pixels.")
    _modes.set_tab_tooltip(Mode.HISTORY,
            "Every edit made to this image's stack this session.\nClick one to rewind to it. Held in memory only, and never saved.")
    _modes.set_tab_tooltip(Mode.RENAME,
            "Write the files out under new names, pixels untouched.\nDescribes the whole batch rather than one image, so it is not part of the stack.")

    column.add_child(HSeparator.new())
    column.add_child(_build_output_section())

    return column


## Fills one stack entry's form. Handed to the stack view so it does not have to know
## about the settings builder.
func _build_entry_form(stage: IWStackOperation, box: VBoxContainer, entry: Control, uid: int) -> void:
    SettingsBuilder.build(stage, box, func() -> void: entry.setting_changed.emit(entry),
            _fold_state, str(uid))


## Switches between the stack and the file operation.
##
## Setting the tab is what shows the right page; everything below is what has to
## follow from having switched. Assigning a tab that is already current raises no
## signal, so calling this from [method _on_tab_changed] cannot loop.
func _select_mode(mode: int) -> void:
    # Any pending write belongs to whatever was showing, and the flush resolves it
    # against the current mode — so it has to go first.
    _flush_autosave()
    var previous := _mode
    _mode = mode
    if _modes != null and _modes.current_tab != mode:
        _modes.current_tab = mode

    # Rename has nothing to pick off the preview, and leaving a crosshair armed over a
    # form that is no longer showing would be a click nobody could explain.
    _release_pick()
    _update_overlays()
    _refresh_suffix()

    # The other side's result no longer describes anything, so it must not be left on
    # screen — under a fade it would be presented as this one's. Crossing between
    # Operations and History is not that: both are the stack, the result on screen is
    # still the stack's, and blanking it would make looking at the history cost the
    # picture you were looking at it about.
    if (previous == Mode.RENAME) != (mode == Mode.RENAME):
        _result_image = null
    _update_preview_texture()
    _update_detail_label()
    if mode != Mode.RENAME and _auto_preview_allowed():
        _schedule_preview()


func _on_tab_changed(tab: int) -> void:
    _select_mode(tab)


func _build_output_section() -> Control:
    var section := VBoxContainer.new()

    var title := Label.new()
    title.text = "Output"
    section.add_child(title)

    var suffix_row := HBoxContainer.new()
    section.add_child(suffix_row)
    var suffix_label := Label.new()
    suffix_label.text = "Suffix"
    suffix_label.tooltip_text = SUFFIX_TOOLTIP
    # A Label ignores the mouse by default, which would swallow the tooltip along
    # with everything else. Pass rather than stop, so the label reports the hover
    # without claiming clicks it has no use for.
    suffix_label.mouse_filter = Control.MOUSE_FILTER_PASS
    suffix_row.add_child(suffix_label)
    _suffix_edit = LineEdit.new()
    _suffix_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _suffix_edit.tooltip_text = SUFFIX_TOOLTIP
    _suffix_edit.text_changed.connect(func(_text: String) -> void: _suffix_is_default = false)
    suffix_row.add_child(_suffix_edit)

    _process_selected_button = Button.new()
    _process_selected_button.text = "Process Current Only"
    _process_selected_button.tooltip_text = "Process the selected image and ask where to save it."
    _process_selected_button.pressed.connect(_on_process_selected)
    section.add_child(_process_selected_button)

    _process_all_button = Button.new()
    _process_all_button.text = "Process All"
    _process_all_button.tooltip_text = "Process every image in the list and ask for a folder to put them in."
    _process_all_button.pressed.connect(_on_process_all)
    section.add_child(_process_all_button)

    return section


func _build_dialogs() -> void:
    _open_dialog = FileDialog.new()
    _open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
    _open_dialog.access = FileDialog.ACCESS_FILESYSTEM
    _open_dialog.title = "Add Images"
    var patterns := PackedStringArray()
    for extension: String in SUPPORTED_EXTENSIONS:
        patterns.append("*." + extension)
    _open_dialog.add_filter(", ".join(patterns), "Images")
    _open_dialog.files_selected.connect(_add_sources)
    add_child(_open_dialog)

    _output_dialog = FileDialog.new()
    _output_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
    _output_dialog.access = FileDialog.ACCESS_FILESYSTEM
    _output_dialog.title = "Process All Into Folder"
    _output_dialog.dir_selected.connect(_on_output_dir_chosen)
    add_child(_output_dialog)

    # Save mode prompts about an existing file itself, which is why the single
    # image path does not also go through the overwrite dialog.
    _save_dialog = FileDialog.new()
    _save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
    _save_dialog.access = FileDialog.ACCESS_FILESYSTEM
    _save_dialog.title = "Save Processed Image"
    _save_dialog.add_filter("*.png", "PNG Image")
    _save_dialog.file_selected.connect(_on_save_file_chosen)
    add_child(_save_dialog)

    _overwrite_dialog = ConfirmationDialog.new()
    _overwrite_dialog.title = "Overwrite Existing Files?"
    _overwrite_dialog.ok_button_text = "Overwrite"
    _overwrite_dialog.confirmed.connect(_write_pending_outputs)
    _overwrite_dialog.canceled.connect(func() -> void: _pending_outputs.clear())
    add_child(_overwrite_dialog)

    _removal_dialog = ConfirmationDialog.new()
    _removal_dialog.title = "Remove Old Files?"
    _removal_dialog.ok_button_text = "Remove"
    _removal_dialog.confirmed.connect(_verify_then_remove_sources)
    _removal_dialog.canceled.connect(func() -> void: _pending_removals.clear())
    add_child(_removal_dialog)

    # A stack file is not an image and does not belong in the Images list, so these two
    # are their own dialogs rather than a mode of the ones above.
    _stack_save_dialog = FileDialog.new()
    _stack_save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
    _stack_save_dialog.access = FileDialog.ACCESS_FILESYSTEM
    _stack_save_dialog.title = "Save Operation Stack"
    _stack_save_dialog.add_filter("*.json", "Operation Stack")
    _stack_save_dialog.current_file = "operations.json"
    _stack_save_dialog.file_selected.connect(_on_stack_save_chosen)
    add_child(_stack_save_dialog)

    _stack_load_dialog = FileDialog.new()
    _stack_load_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
    _stack_load_dialog.access = FileDialog.ACCESS_FILESYSTEM
    _stack_load_dialog.title = "Load Operation Stack"
    _stack_load_dialog.add_filter("*.json", "Operation Stack")
    _stack_load_dialog.file_selected.connect(_on_stack_load_chosen)
    add_child(_stack_load_dialog)

    # The text is fixed, unlike the two above, which name the files they are about. There
    # is only one thing this can do and only one image it can do it to.
    _reset_dialog = ConfirmationDialog.new()
    _reset_dialog.title = "Reset Operations?"
    _reset_dialog.ok_button_text = "Reset"
    _reset_dialog.dialog_text = ("Are you sure you want to reset to the default operation "
            + "stack? History will be lost.")
    _reset_dialog.confirmed.connect(_reset_stack)
    add_child(_reset_dialog)


# --- Sources ------------------------------------------------------------

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
    if not (data is Dictionary) or data.get("type", "") != "files":
        return false
    for path in data.get("files", []):
        if _is_supported(String(path)):
            return true
    return false


func _drop_data(_at_position: Vector2, data: Variant) -> void:
    _add_sources(data.get("files", PackedStringArray()))


static func _is_supported(path: String) -> bool:
    return SUPPORTED_EXTENSIONS.has(path.get_extension().to_lower())


func _add_sources(paths: PackedStringArray) -> void:
    var skipped := 0
    var first_new := -1
    for raw_path in paths:
        var path := String(raw_path)
        if not _is_supported(path):
            skipped += 1
            continue
        if _sources.has(path):
            continue
        if first_new < 0:
            first_new = _sources.size()
        _sources.append(path)

    _refresh_file_list()
    if first_new >= 0 and _file_list.get_selected_items().is_empty():
        _file_list.select(first_new)
        _on_file_selected(first_new)
    elif skipped > 0:
        _set_status("Skipped %d unsupported file(s)." % skipped)
    _update_controls()


func _refresh_file_list() -> void:
    var selected := _selected_index()
    _file_list.clear()
    for path in _sources:
        var index := _file_list.add_item(path.get_file())
        _file_list.set_item_tooltip(index, path)
    if selected >= 0 and selected < _file_list.item_count:
        _file_list.select(selected)


func _selected_index() -> int:
    var selection := _file_list.get_selected_items()
    return selection[0] if not selection.is_empty() else -1


func _on_remove_pressed() -> void:
    var index := _selected_index()
    if index < 0:
        return
    # Its settings go with it, but its sidecar does not: the button's tooltip
    # promises the file is not touched, and a settings file beside the art is a
    # file. Re-adding the image loads it back.
    _flush_autosave()
    _stacks_by_path.erase(_sources[index])
    _sources.remove_at(index)
    _source_image = null
    _result_image = null
    _refresh_file_list()
    if _file_list.item_count > 0:
        var next := mini(index, _file_list.item_count - 1)
        _file_list.select(next)
        _on_file_selected(next)
    else:
        _preview.set_image(null)
        _clear_settings_context()
        _set_status("No image selected.")
        _detail_label.text = ""
    _update_controls()


## Empties the Images list. Like Remove, this only changes what the dock is
## pointed at — nothing on disk is touched, and any sidecars stay where they are
## to be picked up again if the same files are re-added.
func _on_clear_pressed() -> void:
    if _sources.is_empty():
        return
    # A pending write goes out before the entry it belongs to disappears.
    _flush_autosave()
    _sources = PackedStringArray()
    _stacks_by_path.clear()
    _autosave_failures.clear()
    _source_image = null
    _result_image = null
    _refresh_file_list()
    _preview.set_image(null)
    _clear_settings_context()
    _set_status("No image selected.")
    _detail_label.text = ""
    _update_controls()


func _on_file_selected(index: int) -> void:
    if index < 0 or index >= _sources.size():
        return
    # The outgoing image's pending write goes out before the settings swap, or it
    # would be written against whatever came next.
    _flush_autosave()
    var path := _sources[index]
    _source_image = _load_image(path)
    _result_image = null
    if _source_image == null:
        _set_status("Could not read %s" % path.get_file())
        _detail_label.text = ""
        _preview.set_image(null)
        _clear_settings_context()
        _update_controls()
        return

    # The settings belong to this image, and the form must agree with them before
    # anything is processed, so both happen before the preview below.
    _apply_stack_for(path)

    _update_controls()
    # The new source goes up first, whatever happens next. Processing is off on a
    # worker now, so waiting for it would leave the previous image on screen for
    # as long as this one takes — and that is exactly backwards.
    _update_preview_texture()
    _update_detail_label()
    if _auto_preview_allowed():
        _run_preview()
    else:
        # Left to Refresh. Processing a very large image on every click through the
        # list would make the list unusable.
        _set_status("%s is large; press Refresh to process it." % path.get_file())
    # A newly opened image starts fitted, so it arrives filling the frame rather
    # than as a corner crop or a speck in the middle.
    _preview.fit_to_view()


static func _load_image(path: String) -> Image:
    var image := Image.load_from_file(path)
    if image == null or image.is_empty():
        return null
    return image


# --- The stack and preview ----------------------------------------------

## Rebuilds the stack view from [param path]'s saved stack.
##
## With no image selected there is no saved stack, and the default one is shown
## instead — an empty column with nothing above it but a dropdown reads as broken, and
## the first thing anyone does with a fresh dock is add an image anyway.
func _apply_stack_for(path: String) -> void:
    _refreshing = true
    var stages: Array[IWStackOperation] = []
    if path.is_empty():
        stages = _default_stages()
    else:
        for record: Dictionary in _stack_for(path):
            var stage: IWStackOperation = record["operation"]
            stage.set_settings(record["settings"])
            stage.enabled = bool(record["enabled"])
            stages.append(stage)
    _stack_view.set_stages(stages)
    _refreshing = false

    # The shadow has to describe this image before anything can be diffed against it, and
    # the history has to be seeded from the same moment or its first row would be some
    # other image's stack. Both before any edit can arrive, which is why they are here
    # rather than anywhere the selection is handled.
    _shadow_text = JSON.stringify(SettingsIO.encode_stack(_stack_records()))
    if not path.is_empty():
        _history_for(path)
    _refresh_history_view()


## A fresh instance of each operation in [constant DEFAULT_STACK], in order.
func _default_stages() -> Array[IWStackOperation]:
    var stages: Array[IWStackOperation] = []
    for script_path: String in DEFAULT_STACK:
        var script: Script = load(script_path)
        if script == null:
            push_error("Image Wrangler: could not load operation script at %s" % script_path)
            continue
        stages.append(script.new())
    return stages


## Rewires everything that cached what the entries built.
##
## Called after any rebuild, because a rebuild throws every control away — the
## settings Resources survive it, the [Control]s do not.
func _on_entries_rebuilt() -> void:
    _pick_controls.clear()
    for entry: Control in _stack_view.entries():
        for control: Control in entry.pick_controls():
            _pick_controls.append(control)
            _bind_pick_control(control)
    # Through the same pass the rest of the stack goes through, because a note is
    # about what is above an entry rather than about the entry, and asking each one
    # on its own gets that wrong in exactly the cases the note exists for.
    _refresh_notes()
    # A fresh set of forms never inherits a crosshair from the set before it.
    _release_pick()
    _update_overlays()
    _refresh_suffix()


## Connects one picker or drawing control to the dock.
##
## Bound per instance rather than looked up by type, because the stack may hold any
## number of each and a click has to reach the one that is actually armed.
func _bind_pick_control(control: Control) -> void:
    if control is IslandPicker:
        var picker := control as IslandPicker
        picker.pick_toggled.connect(_on_pick_toggled.bind(picker))
        picker.islands_changed.connect(_on_islands_changed)
        picker.selection_changed.connect(_on_selection_changed.bind(picker))
        picker.set_color_provider(_sample_source_color)
    elif control is ColorList:
        var colors := control as ColorList
        colors.pick_toggled.connect(_on_pick_toggled.bind(colors))
        colors.colors_changed.connect(_on_setting_changed)
    elif control is PolygonList:
        var polygons := control as PolygonList
        # Drawing is a pick mode like any other, so it joins the same arbitration:
        # arming it disarms whichever control held the crosshair.
        polygons.draw_toggled.connect(_on_pick_toggled.bind(polygons))
        polygons.polygons_changed.connect(_on_setting_changed)
        polygons.selection_changed.connect(_on_selection_changed.bind(polygons))


## The stack gained, lost or reordered an entry.
func _on_stack_changed() -> void:
    if _refreshing:
        return
    _release_pick_if_disabled()
    _store_stack(_current_path())
    _capture_history()
    _refresh_notes()
    _schedule_autosave()
    _refresh_suffix()
    if _auto_preview_allowed():
        _schedule_preview()
    else:
        _set_status("Stack changed. Press Refresh to update the preview.")


## Writes what the stack view now holds back into this image's saved stack.
func _store_stack(path: String) -> void:
    if path.is_empty():
        return
    _stacks_by_path[path] = _stack_records()


# --- History ------------------------------------------------------------

## Records whatever just changed about the stack, if anything did.
##
## [b]Called from the two funnels every edit already passes through[/b] — [method
## _on_setting_changed] and [method _on_stack_changed] — rather than from the places
## edits are made. That is the whole reason the history can claim to be complete: a
## generated spinner, an island picked off the preview, a dragged polygon vertex, a
## reorder and a pasted stack all arrive here, and so will whatever the next operation
## brings with it. Wiring the sources instead would mean a list to keep in step, and the
## failure mode of forgetting one is an edit that silently cannot be undone.
##
## What it does is diff: the stack as it stands against [member _shadow_text], which is
## how it stood after the last thing recorded. No difference, no command — these funnels
## fire for edits that changed nothing, and rows that do nothing are worse than no rows.
func _capture_history() -> void:
    if _applying_history or _refreshing:
        return
    var path := _current_path()
    if path.is_empty():
        return

    var after := SettingsIO.encode_stack(_stack_records())
    var after_text := JSON.stringify(after)
    if after_text == _shadow_text:
        return

    var history := _history_for(path)
    var before := history.current_state()
    var described := _describe_change(before, after)
    if not _pending_label.is_empty():
        # An edit that knows its own name. The diff would call a wholesale replacement
        # whatever the sizes happened to work out to, which is not what happened.
        described = _plain(_pending_label)
        _pending_label = ""
    var key: StringName = described["merge_key"]

    # Asked before describing, so a gesture already under way is described from where it
    # started rather than from its last step. See IWCommand.absorb.
    var top: IWCommand = history.mergeable_top(key, Time.get_ticks_msec())
    if top != null:
        described = _describe_change(top.before, after)

    history.record(IWCommand.new(
            described["label"], key, before, after, _apply_history_state))
    _shadow_text = after_text
    _refresh_history_view()


## The history for one image, seeded from what is on screen the first time it is asked
## for.
##
## Seeded rather than left empty so the first row is the state the image opened in, which
## is what makes the very first edit reversible.
func _history_for(path: String) -> IWHistory:
    if _history_by_path.has(path):
        return _history_by_path[path]
    var history := IWHistory.new()
    history.seed(SettingsIO.encode_stack(_stack_records()))
    _history_by_path[path] = history
    return history


## Puts the stack into a recorded state. Handed to every [IWCommand] as its applier.
##
## Deliberately only the state. A rewind of forty steps calls this forty times, and doing
## the preview, the autosave and the notes each time would be thirty-nine runs of work
## nobody asked for against states nobody will see. Those happen once, in [method
## _on_history_revert], after the last step has landed.
func _apply_history_state(state: Array) -> void:
    var registry := _operation_registry()
    var stages: Array[IWStackOperation] = []
    for record: Dictionary in SettingsIO.decode_stack_records(state, registry, "the history"):
        var script: Variant = registry.get(record["id"])
        if not (script is Script):
            continue
        var stage: IWStackOperation = (script as Script).new()
        stage.set_settings(record["settings"])
        stage.enabled = bool(record["enabled"])
        stages.append(stage)

    # Both flags, and for different reasons: _refreshing stops the rebuild being read as
    # a settings edit, _applying_history stops anything that slips past it being recorded.
    var was_refreshing := _refreshing
    _refreshing = true
    _applying_history = true
    _stack_view.set_stages(stages)
    _applying_history = false
    _refreshing = was_refreshing


## A row in the History tab was clicked.
func _on_history_revert(index: int) -> void:
    var path := _current_path()
    if path.is_empty() or not _history_by_path.has(path):
        return
    var history: IWHistory = _history_by_path[path]
    if index == history.current_index():
        return

    history.go_to(index)

    # The state is in place; everything that follows from it happens once, here.
    _shadow_text = JSON.stringify(history.current_state())
    _store_stack(path)
    _refresh_notes()
    _refresh_suffix()
    _schedule_autosave()
    _refresh_history_view()
    if _auto_preview_allowed():
        _schedule_preview()
    else:
        _set_status("Rewound. Press Refresh to update the preview.")


func _refresh_history_view() -> void:
    if _history_view == null:
        return
    var path := _current_path()
    if path.is_empty() or not _history_by_path.has(path):
        _history_view.set_rows([], IWHistory.BASE_INDEX)
        return
    var history: IWHistory = _history_by_path[path]
    _history_view.set_rows(history.rows(), history.current_index())


# --- Describing an edit -------------------------------------------------

## What to call the difference between two stack states, and which consecutive edits it
## is the same gesture as.
##
## Returns [code]{"label": String, "merge_key": StringName}[/code]. An empty merge key
## never folds into anything, which is right for every structural edit: adding a stage
## twice is two additions, however fast they were done.
func _describe_change(before: Array, after: Array) -> Dictionary:
    var before_ids := _ids_of(before)
    var after_ids := _ids_of(after)

    if before_ids != after_ids:
        if after.size() > before.size():
            return _plain("Add %s" % _added_name(before_ids, after_ids))
        if after.size() < before.size():
            return _plain("Remove %s" % _added_name(after_ids, before_ids))
        return _plain("Reorder operations")

    for i in after.size():
        var was := bool((before[i] as Dictionary).get("enabled", true))
        var now := bool((after[i] as Dictionary).get("enabled", true))
        if was != now:
            return _plain("%s %s" % ["Enable" if now else "Disable", _name_for_id(after_ids[i])])

    for i in after.size():
        var was_settings: Dictionary = (before[i] as Dictionary).get("settings", {})
        var now_settings: Dictionary = (after[i] as Dictionary).get("settings", {})
        if JSON.stringify(was_settings) == JSON.stringify(now_settings):
            continue
        var stage_name := _name_for_id(after_ids[i])
        var property := _sole_scalar_change(was_settings, now_settings)
        if property.is_empty():
            # A list control rewrote a nested Resource, or several values moved at once.
            # Nothing useful to name, but it still merges, so dragging a polygon vertex
            # is one row rather than one per frame of the drag.
            return {"label": "%s settings" % stage_name,
                    "merge_key": StringName("stage:%d" % i)}
        return {
            "label": "%s %s" % [_label_for(i, property), _transition(i, property,
                    was_settings[property], now_settings[property])],
            "merge_key": StringName("set:%d:%s" % [i, property]),
        }

    return _plain("Changed")


func _plain(text: String) -> Dictionary:
    return {"label": text, "merge_key": &""}


func _ids_of(state: Array) -> PackedStringArray:
    var out := PackedStringArray()
    for record: Dictionary in state:
        out.append(String(record.get("id", "")))
    return out


## The first id [param bigger] has that [param smaller] does not account for, as a display
## name. Used for both directions — an addition is what the new list has spare, and a
## removal is what the old one had.
func _added_name(smaller: PackedStringArray, bigger: PackedStringArray) -> String:
    var counts := {}
    for id: String in smaller:
        counts[id] = int(counts.get(id, 0)) + 1
    for id: String in bigger:
        var left := int(counts.get(id, 0))
        if left <= 0:
            return _name_for_id(id)
        counts[id] = left - 1
    return "an operation"


## The one property that changed, or an empty String when it was not exactly one, or not
## something worth quoting a value for.
func _sole_scalar_change(before: Dictionary, after: Dictionary) -> String:
    var found := ""
    for key: Variant in after:
        var was: Variant = before.get(key)
        if JSON.stringify(was) == JSON.stringify(after[key]):
            continue
        if not found.is_empty():
            return ""
        match typeof(after[key]):
            TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
                found = String(key)
            _:
                return ""
    # A key the new state has lost is a change too, and not one to put a value on.
    for key: Variant in before:
        if not after.has(key):
            return ""
    return found


## What the schema calls a property, so a row reads the way the control it came from is
## labelled rather than the way the variable is spelled.
func _label_for(stage_index: int, property: String) -> String:
    var entry := _schema_entry(stage_index, property)
    if entry.has("label"):
        return String(entry["label"])
    return property.capitalize()


## One value to another, in the terms the control uses: an enum by its option's name, a
## bool as on or off, a float without the trailing noise a plain cast leaves.
func _transition(stage_index: int, property: String, was: Variant, now: Variant) -> String:
    var entry := _schema_entry(stage_index, property)
    return "%s → %s" % [_value_text(entry, was), _value_text(entry, now)]


func _value_text(entry: Dictionary, value: Variant) -> String:
    if typeof(value) == TYPE_BOOL:
        return "on" if value else "off"
    if int(entry.get("type", -1)) == IWOperation.SettingType.ENUM:
        var options: Array = entry.get("options", [])
        var at := int(value)
        if at >= 0 and at < options.size():
            return String(options[at])
    if typeof(value) == TYPE_FLOAT:
        return String.num(float(value), 3).rstrip("0").rstrip(".")
    if typeof(value) == TYPE_STRING:
        return "\"%s\"" % String(value)
    return str(value)


## The schema entry a stage declares for one property, or an empty Dictionary.
func _schema_entry(stage_index: int, property: String) -> Dictionary:
    if _stack_view == null:
        return {}
    var stages: Array = _stack_view.stages()
    if stage_index < 0 or stage_index >= stages.size():
        return {}
    for entry: Dictionary in (stages[stage_index] as IWStackOperation).get_settings_schema():
        if String(entry.get("property", "")) == property:
            return entry
    return {}


## The display name for an operation id.
func _name_for_id(id: String) -> String:
    if _operation_names.is_empty():
        for script_path: String in OPERATION_SCRIPTS:
            var script: Script = load(script_path)
            if script == null:
                continue
            var probe: IWOperation = script.new()
            _operation_names[String(probe.get_operation_id())] = probe.get_operation_name()
    return String(_operation_names.get(id, id))


## The live stack in the codec's record shape, which is what both the sidecar and the
## clipboard take.
##
## The live operation rides along under [code]"operation"[/code] for [method
## _apply_stack_for] to point the forms back at. Neither encoder looks at it.
func _stack_records() -> Array:
    var records := []
    for stage: IWStackOperation in _stack_view.stages():
        records.append({
            "id": stage.get_operation_id(),
            "enabled": stage.enabled,
            "settings": stage.get_settings(),
            "operation": stage,
        })
    return records


## Puts the whole stack on the clipboard, settings and all.
##
## A snapshot rather than a reference: [method IWSettingsIO.to_dict] reads the values
## out on the way past, so editing a slider afterwards does not reach back into what was
## copied.
func _on_copy_stack() -> void:
    var records := _stack_records()
    if records.is_empty():
        _set_status("There is nothing in the stack to copy.")
        return
    DisplayServer.clipboard_set(SettingsIO.stack_to_text(records))
    _set_status("Copied %s to the clipboard." % _operation_count(records.size()))


## Adds whatever stack is on the clipboard to the bottom of this one.
##
## Adds where Load replaces, and the difference is what each one is for. A paste is a
## piece of another stack being brought over; a file is a whole stack being restored.
func _on_paste_stack() -> void:
    var stages := _stages_from_text(DisplayServer.clipboard_get())
    if stages.is_empty():
        _set_status("Found no operation stack on the clipboard.")
        return
    # Emits stack_changed, which stores, re-notes and reruns. The status is set after,
    # because what just happened is more use than being told the stack changed.
    _stack_view.add_stages(stages)
    _set_status("Added %s from the clipboard." % _operation_count(stages.size()))


## Writes the whole stack out as a file that can be loaded back.
func _on_save_stack() -> void:
    if _stack_view.is_empty():
        _set_status("There is nothing in the stack to save.")
        return
    _stack_save_dialog.popup_centered_ratio(0.6)


func _on_stack_save_chosen(path: String) -> void:
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        _set_status("Could not write %s." % path.get_file())
        return
    # Indented, unlike the clipboard's copy: this one lands somewhere a person may open
    # it and read it.
    file.store_string(SettingsIO.stack_to_text(_stack_records(), "\t"))
    file.close()
    _set_status("Saved %s to %s." % [
        _operation_count(_stack_view.stages().size()), path.get_file(),
    ])


func _on_load_stack() -> void:
    _stack_load_dialog.popup_centered_ratio(0.6)


## Replaces this image's stack with the one in the chosen file.
##
## [b]Replaces, where Paste adds.[/b] A file is a stack somebody saved whole and means to
## get back whole, so anything already there would only be in the way. Nothing is lost
## that cannot be recovered: the replacement goes into History like any other edit, so it
## rewinds.
func _on_stack_load_chosen(path: String) -> void:
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        _set_status("Could not read %s." % path.get_file())
        return
    var text := file.get_as_text()
    file.close()

    var stages := _stages_from_text(text)
    if stages.is_empty():
        _set_status("Found no operation stack in %s." % path.get_file())
        return

    _pending_label = "Load %s" % path.get_file()
    _refreshing = true
    _stack_view.set_stages(stages)
    _refreshing = false
    # set_stages does not announce, because swapping images uses it too. Everything that
    # has to follow a stack changing is in here.
    _on_stack_changed()
    _set_status("Loaded %s from %s." % [
        _operation_count(stages.size()), path.get_file(),
    ])


## The operations [param text] describes, or an empty Array when it describes none.
##
## Every settings object is built fresh by the codec, so the same file loaded onto two
## images gives each its own and editing one does not move the other.
func _stages_from_text(text: String) -> Array[IWStackOperation]:
    var registry := _operation_registry()
    var stages: Array[IWStackOperation] = []
    for record: Dictionary in SettingsIO.stack_from_text(text, registry):
        var script: Variant = registry.get(record["id"])
        if not (script is Script):
            continue
        var stage: IWStackOperation = (script as Script).new()
        stage.set_settings(record["settings"])
        stage.enabled = bool(record["enabled"])
        stages.append(stage)
    return stages


func _operation_count(count: int) -> String:
    return "1 operation" if count == 1 else "%d operations" % count


## Reset was pressed. Always asks, even from an untouched stack.
##
## No "nothing to reset" shortcut, because there is nearly always something: the sidecar
## this would discard, or the history behind it. Working out whether this particular press
## happened to be a no-op would be a rule the user has to learn in order to trust the
## button, and the dialog costs a keystroke.
func _on_reset_stack() -> void:
    if _current_path().is_empty():
        _set_status("Select an image before resetting its operations.")
        return
    _reset_dialog.popup_centered()


## Puts the stack back to the default and throws this image's history away.
##
## [b]The history goes rather than gaining a row.[/b] Recording the reset as an edit would
## make it undoable, which sounds kinder and is the wrong promise: the point of the
## confirmation is that this is the way out of a stack that has gone wrong, and a way out
## that leaves the wreckage one click behind it is not one. The dialog says so before
## anything happens.
##
## The sidecar is rewritten on the usual timer rather than deleted. What is on disk should
## agree with what is on screen, and what is on screen is now the default.
func _reset_stack() -> void:
    var path := _current_path()
    if path.is_empty():
        return

    _refreshing = true
    _stack_view.set_stages(_default_stages())
    _refreshing = false

    _store_stack(path)
    # Rebuilt rather than cleared, so the first row is the default this just arrived at
    # instead of a state nothing can reach any more.
    _history_by_path.erase(path)
    _shadow_text = JSON.stringify(SettingsIO.encode_stack(_stack_records()))
    _history_for(path)
    _refresh_history_view()

    _refresh_notes()
    _refresh_suffix()
    _schedule_autosave()
    _set_status("Operations reset to the default.")
    if _auto_preview_allowed():
        _schedule_preview()


## Refreshes every entry's "waiting for" line against what the stack now looks like.
##
## Answered without a run, so it can only speak about the stack rather than about the
## image: whether something above establishes keys, and whether a classification will
## exist by the time each stage is reached.
func _refresh_notes() -> void:
    var keying := false
    for entry: Control in _stack_view.entries():
        var stage: IWStackOperation = entry.stage
        entry.set_note("" if keying or not stage.needs_keying() else stage.prerequisite_note(null))
        if stage.enabled and stage.establishes_keying():
            keying = true


## Puts the output suffix back to what the current mode suggests.
##
## Only while the user has not claimed the field as their own — once it has been
## typed in, changing the stack must not take it away again.
func _refresh_suffix() -> void:
    if not _suffix_is_default:
        return
    _suffix_edit.text = _active_operation().get_output_suffix() if _active_operation() != null else "_out"


## The operation the Process buttons would run, built fresh from what is on screen.
func _active_operation() -> IWOperation:
    if _mode == Mode.RENAME:
        return _rename
    var pipeline := IWPipeline.new()
    for stage: IWStackOperation in _stack_view.stages():
        pipeline.stages.append(stage)
    return pipeline


## Takes the crosshair back if whichever control holds it has just been switched off.
##
## Its button is disabled along with the rest of the entry's form, so without this the
## preview would stay in pick mode with no way to leave it — the click would still
## land, and the button that turns it off would be unpressable.
func _release_pick_if_disabled() -> void:
    if _pick_target == null:
        return
    for entry: Control in _stack_view.entries():
        if entry.stage.enabled:
            continue
        if _pick_target in entry.pick_controls():
            _release_pick()
            return


## Drops out of pick mode, leaving every control's button unpressed.
func _release_pick() -> void:
    _pick_target = null
    _preview.pick_mode = false
    _preview.region_pick = false
    for control: Control in _pick_controls:
        if control is PolygonList:
            # Committed rather than abandoned: leaving a half-drawn shape open would
            # strand it on the list with no way back into the session that owns it.
            (control as PolygonList).finish_polygon()
        control.set_pick_active(false)


## Path of the highlighted source, or an empty string when nothing is selected.
func _current_path() -> String:
    var index := _selected_index()
    if index < 0 or index >= _sources.size():
        return ""
    return _sources[index]


## The stack for one source, created on demand.
##
## An image with no sidecar gets the default stack, not whatever the last image was
## tuned to. Values that arrived by inheritance look identical to values that were
## chosen, so a form that carries them over cannot say which it is showing — and the
## answer decides whether the sidecar about to be autosaved is a real record of this
## image or an accident of what was selected before it.
##
## The cost is that a batch has to be tuned per image rather than dialled in once,
## which is the trade being made deliberately: the form shows exactly what processing
## will use, for every image, whether or not it was ever selected.
##
## Each record is [code]{id, enabled, settings, operation}[/code]. The operation is the
## live instance the form is pointed at; the rest is what the sidecar stores.
func _stack_for(path: String) -> Array:
    if path.is_empty():
        return []
    if _stacks_by_path.has(path):
        return _stacks_by_path[path]

    var loaded := SettingsIO.load_stack(path, _operation_registry())
    var records := []
    if loaded.is_empty():
        for stage in _default_stages():
            records.append({
                "id": stage.get_operation_id(),
                "enabled": true,
                "settings": stage.get_settings(),
                "operation": stage,
            })
    else:
        var registry := _operation_registry()
        for entry: Dictionary in loaded:
            var script: Variant = registry.get(entry["id"])
            if not (script is Script):
                continue
            var stage: IWStackOperation = (script as Script).new()
            var settings: Resource = entry["settings"]
            # Clamped here rather than after the swap, so the batch path — which never
            # goes through _apply_stack_for — gets it too.
            stage.clamp_settings_to_schema(settings)
            stage.set_settings(settings)
            stage.enabled = bool(entry["enabled"])
            records.append({
                "id": entry["id"],
                "enabled": stage.enabled,
                "settings": settings,
                "operation": stage,
            })

    _stacks_by_path[path] = records
    return records


## Operation id to script, for the sidecar codec and the stack loader.
func _operation_registry() -> Dictionary:
    var registry := {}
    for script_path: String in OPERATION_SCRIPTS:
        var script: Script = load(script_path)
        if script == null:
            continue
        var probe: IWOperation = script.new()
        registry[probe.get_operation_id()] = script
    return registry


## Writes the sidecar for whichever image the pending save belongs to.
func _flush_autosave() -> void:
    if _autosave != null:
        _autosave.stop()
    var path := _autosave_path
    _autosave_path = ""
    if path.is_empty():
        return

    # Read rather than resolve: resolving would create and cache an entry, so a stale
    # pending path could write a sidecar for an image never touched.
    if not _stacks_by_path.has(path):
        return
    var error := SettingsIO.save_stack(path, _stacks_by_path[path])
    if error == OK:
        _autosave_failures.erase(path)
        return
    if _autosave_failures.has(path):
        return
    _autosave_failures[path] = true
    if error == ERR_FILE_CORRUPT:
        _set_status("Cannot save settings: %s already exists and was written by something else."
                % SettingsIO.sidecar_path(path).get_file())
    else:
        _set_status("Could not write settings for %s." % path.get_file())


func _schedule_autosave() -> void:
    if _mode == Mode.RENAME:
        # Nothing to save: a rename scheme describes the batch rather than any one
        # file, so it is held for the session and never written to a sidecar.
        return
    var path := _current_path()
    if path.is_empty() or _autosave == null:
        return
    # A pending save for a different image is written now rather than dropped.
    if not _autosave_path.is_empty() and _autosave_path != path:
        _flush_autosave()
    _autosave_path = path
    _autosave.start()


## Drops the forms back to a blank context when no image is selected.
##
## The dialled-in values stay put. They describe nothing now — the next image selected
## is resolved from its own sidecar or from the default stack, never from these — but
## blanking a form the moment a row is deselected would throw away work for no gain.
func _clear_settings_context() -> void:
    _refreshing = true
    for stage: IWStackOperation in _stack_view.stages():
        var current := stage.get_settings()
        if current != null and current.has_method("duplicate_for_new_image"):
            # Islands and drawn regions are the exception: they are coordinates in the
            # image that just left, so leaving them on screen would draw markers and
            # outlines over nothing.
            stage.set_settings(current.duplicate_for_new_image())
    # The controls are still holding rows from the lists that were swapped out.
    for control: Control in _pick_controls:
        if control.has_method("refresh"):
            control.call("refresh")
    _update_overlays()
    _refreshing = false


## Colour behind a pixel of the image on screen, for the island row swatches.
func _sample_source_color(pixel: Vector2i) -> Color:
    if _source_image == null:
        return Color.MAGENTA
    if pixel.x < 0 or pixel.y < 0 or pixel.x >= _source_image.get_width() or pixel.y >= _source_image.get_height():
        return Color.MAGENTA
    return _source_image.get_pixelv(pixel)


## Hands the crosshair to [param source], taking it off whoever had it.
##
## Only one control can own the preview, so every other one is released rather than
## left pressed over a picker that no longer receives anything. A loop rather than a
## fixed set, because the stack may hold any number of each.
func _on_pick_toggled(enabled: bool, source: Control) -> void:
    if not enabled:
        # Only when it still holds the crosshair. Otherwise this is the echo of another
        # picker having taken it, not the user switching picking off.
        if _pick_target == source:
            _pick_target = null
            _preview.pick_mode = false
            _preview.region_pick = false
            if source is PolygonList:
                (source as PolygonList).finish_polygon()
                _update_overlays()
        return

    # The ones that did not just get pressed are released, rather than left looking
    # pressed over a picker no click will reach. The source's own button is already
    # down, which is what raised this signal.
    for control: Control in _pick_controls:
        if control == source:
            continue
        if control is PolygonList:
            (control as PolygonList).finish_polygon()
        control.set_pick_active(false)

    _pick_target = source
    _overlay_owner = source
    _preview.pick_mode = true
    # Both lists want a rectangle — one takes the pixels inside it, the other the
    # colours. A polygon is built corner by corner and wants neither.
    _preview.region_pick = source is IslandPicker or source is ColorList
    if source is ColorList:
        _set_status("Drag a region in the preview to take every color in it, or click one pixel.")
    elif source is PolygonList:
        _set_status("Click to place corners. Right-click or Escape closes the region.")
    else:
        _set_status("Drag a region in the preview to add it to the list, or click one pixel.")
    _update_overlays()


func _on_pixel_picked(pixel: Vector2i) -> void:
    if _source_image == null or _pick_target == null:
        return
    if _pick_target is PolygonList:
        # add_vertex reports a click on the first corner, which is a request to close
        # rather than a corner of its own.
        if (_pick_target as PolygonList).add_vertex(pixel):
            _finish_polygon()
        else:
            _update_overlays()


## A rectangle swept over the preview. Both lists ask for one, which is what the
## preview's [code]region_pick[/code] is set from.
##
## A click is a one by one region rather than a case of its own, so a single pick
## reports exactly what it always did.
##
## Zero back from either means nothing was added — a repeat of something already
## listed, or a region with nothing in it. The control has said which in its own hint,
## and a status line saying nothing happened would be the same news twice.
func _on_region_picked(region: Rect2i) -> void:
    if _source_image == null:
        return
    if _pick_target is IslandPicker:
        _pick_island_region(region)
    elif _pick_target is ColorList:
        _pick_color_region(region)


func _pick_island_region(region: Rect2i) -> void:
    var picked := (_pick_target as IslandPicker).add_region(region)
    if picked <= 0:
        return
    if region.size == Vector2i.ONE:
        _set_status("Picked (%d, %d)." % [region.position.x, region.position.y])
    else:
        _set_status("Picked (%d, %d)–(%d, %d), %d pixels." % [
            region.position.x,
            region.position.y,
            region.end.x - 1,
            region.end.y - 1,
            picked,
        ])


## Reads the colours out of the region and hands them to the list.
##
## Sampled here rather than in the control for the same reason a swatch is: the image
## belongs to the dock, and a settings control that could reach it would be a control
## that has to be told which image it is looking at.
func _pick_color_region(region: Rect2i) -> void:
    # The colour comes from the source, because that is what the keyer measures against.
    # What the stack has left of the image only says which pixels are still worth
    # asking about — see [method IWRegionScan.colors_in]. Null before the first run,
    # which samples everything, as it did before anything had been removed.
    var colors := IWRegionScan.colors_in(
            _source_image, region, RemoveColorList.SCAN_BUDGET, _result_image)
    var added := (_pick_target as ColorList).add_region(colors, region)
    if added <= 0:
        return
    # Named only when the pick was one pixel, where the colour taken can only be the
    # one colour found. Past that the list thins what it was handed, so the first
    # colour of the sweep is not necessarily among the ones it kept.
    if region.size == Vector2i.ONE:
        _set_status("Picked #%s." % colors[0].to_html(false))
    else:
        _set_status("Picked %d of the %d colors in that region." % [added, colors.size()])


## Whichever polygon list currently owns the crosshair, or null.
##
## Unambiguous in a way "the one polygon list" never was: with several in the stack,
## Escape and Backspace address the shape actually being drawn.
func _drawing_list() -> PolygonList:
    return _pick_target as PolygonList


## Closes the region being drawn and drops out of drawing, so the Draw button does not
## sit armed over a session that has ended.
func _finish_polygon() -> void:
    var drawing := _drawing_list()
    if drawing == null:
        return
    drawing.finish_polygon()
    drawing.set_pick_active(false)
    _pick_target = null
    _preview.pick_mode = false
    _update_overlays()


## Right-click on the preview. Only the polygon tool makes anything of it.
func _on_pick_cancelled() -> void:
    if _drawing_list() != null:
        _finish_polygon()


func _on_vertex_dragged(polygon: int, vertex: int, to: Vector2i) -> void:
    # The drag is reported against the merged overlay, so it has to be resolved back
    # to whichever list owns that region and to its own index within it.
    var owner := _region_owner(polygon)
    if owner == null:
        return
    # Overlay only. Re-running the stack on every motion event would be unusable on any
    # real image, so the result waits for the drag to end.
    owner[0].move_vertex(polygon - int(owner[1]), vertex, to)
    _overlay_owner = owner[0]
    _update_overlays()


func _on_vertex_drag_ended() -> void:
    _on_setting_changed()


func _on_islands_changed() -> void:
    # Nothing to store: the picker edited the IslandList inside this image's settings
    # directly, so it is already where it belongs.
    _update_overlays()
    _on_setting_changed()


## Remembers whose selection the overlay should highlight.
##
## The preview draws one merged list, so only one control's selection can be shown.
## The last one touched is the right answer: it is the one the user is working in.
func _on_selection_changed(source: Control) -> void:
    _overlay_owner = source
    _update_overlays()


## The polygon list owning merged region [param index], and the offset its own
## indices start at — or null when nothing does.
func _region_owner(index: int) -> Array:
    var offset := 0
    for control: Control in _pick_controls:
        if not (control is PolygonList):
            continue
        var list := control as PolygonList
        var count := list.get_polygons().size()
        if index < offset + count:
            return [list, offset]
        offset += count
    return []


## Pushes both overlays — island markers and drawn regions — at the preview.
##
## One function rather than two because they are drawn together, hidden together by H,
## and every change to either has to leave both correct on screen.
##
## Everything in the stack contributes, concatenated in stack order, because the
## preview takes one flat list of each. Only the selection cannot be merged: an index
## into the joined list means nothing unless it is offset by whatever was drawn before
## its owner, and only one control's selection is shown at a time. See
## [member _overlay_owner].
func _update_overlays() -> void:
    var islands: Array[Rect2i] = []
    var island_flags := PackedByteArray()
    var island_flooded := PackedByteArray()
    var selected_island := -1

    var regions := []
    var region_colors := PackedColorArray()
    var region_flags := PackedByteArray()
    var selected_region := -1
    var draft_region := -1

    if _mode != Mode.RENAME:
        for control: Control in _pick_controls:
            if control is IslandPicker:
                var picker := control as IslandPicker
                var own := picker.get_islands()
                if picker == _overlay_owner and picker.selected_index() >= 0:
                    selected_island = islands.size() + picker.selected_index()
                islands.append_array(own)
                island_flags.append_array(picker.get_enabled_flags())
                island_flooded.append_array(picker.get_flooded_flags())
            elif control is PolygonList:
                var list := control as PolygonList
                var own_regions := list.get_polygons()
                var offset := regions.size()
                if list == _overlay_owner and list.selected_index() >= 0:
                    selected_region = offset + list.selected_index()
                # At most one list has a draft, because drawing is arbitrated.
                if list.draft_index() >= 0:
                    draft_region = offset + list.draft_index()
                regions.append_array(own_regions)
                region_colors.append_array(list.get_colors())
                region_flags.append_array(list.get_enabled_flags())

    _preview.set_markers(islands, selected_island, island_flags, island_flooded)
    _preview.set_polygons(regions, region_colors, selected_region, draft_region, region_flags)


func _on_setting_changed() -> void:
    if _refreshing:
        return
    # A setting can be the switch that hides another one, and nothing but this would
    # notice it had been thrown.
    if _mode == Mode.RENAME:
        SettingsBuilder.refresh_visibility(_rename, _rename_box)
    else:
        for entry: Control in _stack_view.entries():
            SettingsBuilder.refresh_visibility(entry.stage, entry.settings_box())
        # And a setting can be what makes a stage need something above it — the first
        # Subtract island picked is the case — so the notes are asked again too.
        _refresh_notes()
        _capture_history()
    _schedule_autosave()
    if _mode == Mode.RENAME:
        _update_detail_label()
        return
    if _auto_preview_allowed():
        _schedule_preview()
    else:
        _set_status("Settings changed. Press Refresh to update the preview.")


## Whether the preview should follow settings changes on its own.
##
## Only the image's size decides. Below the limit the preview keeps up and there
## is no reason to ask; above it, one tweak of a slider would lock the editor for
## seconds at a time, and Refresh is the way to ask for it deliberately.
func _auto_preview_allowed() -> bool:
    if _source_image == null:
        return false
    return _source_image.get_width() * _source_image.get_height() <= AUTO_PREVIEW_PIXEL_LIMIT


func _schedule_preview() -> void:
    if _source_image == null:
        return
    _debounce.start()


## Fading is a redraw, not a re-run: both images are already on the preview and
## it is only the weight between them that changed.
func _on_original_fade_changed(value: float) -> void:
    _preview.original_fade = value * 0.01


## Asks for a preview, starting one now or replacing the run in flight.
##
## Only ever one worker at a time. A second [Thread] would have to be joined before
## it could be replaced, and joining blocks — which is the whole thing this is here
## to avoid. So a request arriving mid-run tells that run to stop and leaves a note
## to start again; the run bails at its next checkpoint, and the handler that
## collects it starts the replacement.
func _run_preview() -> void:
    _debounce.stop()
    if _shutting_down or _source_image == null or _mode == Mode.RENAME:
        return
    if _preview_running:
        _preview_pending = true
        if _preview_worker_op != null:
            _preview_worker_op.cancelled = true
        return
    _start_preview()


## Hands the operation to a worker thread — or, with threading off, runs it right
## here — and puts the preview into its working state.
func _start_preview() -> void:
    _preview_pending = false
    if _shutting_down:
        return
    var worker := _snapshot_operation()
    if worker == null:
        return

    # Captured, so the handler can tell whether the answer still describes what is
    # on screen. Comparing the Image itself is the exact test: selecting another
    # file replaces the object, and nothing else does.
    var source := _source_image

    # Captured rather than read again when a report arrives: the switch can be flipped
    # mid-run, and a run must report the way it was started or half its numbers would
    # take the other route.
    var threaded := _threading_enabled
    worker.progress_reporter = func(fraction: float) -> void:
        # Deferred when it comes from the worker, since nothing on that side of it may
        # touch a control. Called straight through when the run is on the main thread
        # already — deferring there would land the number after the frame it belongs to.
        if threaded:
            _on_preview_progress.call_deferred(fraction)
        else:
            _on_preview_progress(fraction)
    if worker is IWPipeline:
        (worker as IWPipeline).stage_progress_reporter = func(index: int, count: int, fraction: float, stage_name: String) -> void:
            if threaded:
                _on_preview_stage_progress.call_deferred(index, count, fraction, stage_name)
            else:
                _on_preview_stage_progress(index, count, fraction, stage_name)

    # set_busy resets the bar even when it is already up, so a restart begins from
    # nothing rather than from wherever the abandoned run had got to.
    _preview.set_busy(true)
    _preview_worker_op = worker
    _preview_running = true

    if not threaded:
        _run_preview_here(worker, source)
        return

    _preview_thread = Thread.new()
    _preview_thread.start(_preview_worker.bind(worker, source))


## The run with threading off: on the main thread, a stage at a time.
##
## Stepped rather than run straight through, because a bar nobody can see is not a
## bar. The main thread does the painting, so while it is inside a stack of stages
## nothing on screen changes — set_busy and every report in between would land as one
## repaint at the end, on their way out. Yielding between stages gets each of them
## drawn.
##
## The editor is live during those yields, which the straight-through version never
## was, so everything that guards a threaded run has to hold here too: the request
## arriving mid-run is caught by [member _preview_running] and cancels this one, and
## the answer is dropped if the dock left the tree while a stage was running.
func _run_preview_here(worker: IWOperation, source: Image) -> void:
    var started := Time.get_ticks_msec()
    var result: Image
    if worker is IWPipeline:
        result = await (worker as IWPipeline).process_image_stepped(source, get_tree().process_frame)
    else:
        # Nothing to step through. One call, and the bar stands still for it.
        result = worker.process_image(source)
    if _shutting_down:
        return
    _on_preview_done(source, result, Time.get_ticks_msec() - started)


## The whole of what runs off the main thread.
##
## Touches only the throwaway operation it was handed and the source image, and
## reports back by deferral. Anything else here would be reaching into state the
## editor is free to be changing at the same moment.
func _preview_worker(worker: IWOperation, source: Image) -> void:
    var started := Time.get_ticks_msec()
    var result := worker.process_image(source)
    _on_preview_done.call_deferred(source, result, Time.get_ticks_msec() - started)


func _on_preview_progress(fraction: float) -> void:
    if _shutting_down or not is_instance_valid(_preview):
        return
    _preview.set_progress(fraction)


## The second bar, and the caption naming what is running.
##
## The position is in the label rather than only the name, because a stack may hold
## the same operation twice and "Polygon Edit" on its own would not say which.
func _on_preview_stage_progress(index: int, count: int, fraction: float, stage_name: String) -> void:
    if _shutting_down or not is_instance_valid(_preview):
        return
    _preview.set_stage_progress(fraction, "%s  (%d/%d)" % [stage_name, index + 1, count])


## Takes delivery of a finished run, back on the main thread.
func _on_preview_done(source: Image, result: Image, elapsed: int) -> void:
    # The dock is on its way out and [method _exit_tree] has already joined the thread
    # and let go of it. Nothing below has anywhere to put an answer.
    if _shutting_down:
        return
    if _preview_thread != null:
        # Returns at once — the worker is already done, this is the bookkeeping
        # Thread insists on before it can be let go. Null when the run was unthreaded,
        # which is the whole of the difference by the time an answer gets here.
        _preview_thread.wait_to_finish()
        _preview_thread = null
    # Held on to for the report below: it is the only handle on the stack that actually
    # ran, and everything it observed is recorded on that copy rather than on the live one.
    var worker := _preview_worker_op
    _preview_worker_op = null
    # Before the restart below rather than after, since that sets it again.
    _preview_running = false

    # Kept only while it still describes what is on screen. A run whose image was
    # swapped out under it, or one already superseded by another request, is a
    # picture of something the user has moved on from.
    if source == _source_image and not _preview_pending:
        _result_image = result
        # An operation whose effect is not visible in the pixels — a rename —
        # reports what it would do instead, so it is still inspectable before being
        # run.
        var path := _current_path()
        var active := _active_operation()
        var note := active.describe_output(path, _suffix_edit.text, maxi(_sources.find(path), 0)) if not path.is_empty() else ""
        if note.is_empty():
            _set_status("%s in %d ms" % [_stack_summary(), elapsed])
        else:
            _set_status(note)
        _update_preview_texture()
        _update_detail_label()
        # After the picture rather than before it, and only for a run being kept: a
        # superseded run's answer is a picture of something the user has moved on from,
        # and so is anything it observed on the way.
        _absorb_run_report(worker)
        _update_overlays()

    # Straight into the next run rather than clearing the overlay first, so a held
    # slider does not strobe it off and on between every pass.
    if _preview_pending and _source_image != null and _mode != Mode.RENAME:
        _start_preview()
    else:
        _preview_pending = false
        _preview.set_busy(false)


## Lets every stage take back whatever the run learned that the dock wants to show.
##
## Positional, because the two stacks are the same stack: [method _snapshot_pipeline]
## builds one worker stage per live stage, in order, enabled or not. A mismatch means
## the stack was rebuilt while the run was going, and there is nothing to line the two
## up by — the next run reports against the stack as it now is.
func _absorb_run_report(worker: IWOperation) -> void:
    var pipeline := worker as IWPipeline
    if pipeline == null:
        return
    var live: Array = _stack_view.stages()
    if live.size() != pipeline.stages.size():
        return
    for i in live.size():
        (live[i] as IWStackOperation).absorb_run_report(pipeline.stages[i])


## What the status line calls the run: how many stages actually did anything.
func _stack_summary() -> String:
    var count := 0
    for stage: IWStackOperation in _stack_view.stages():
        if stage.enabled:
            count += 1
    return "1 operation" if count == 1 else "%d operations" % count


## A private pipeline for the worker to use.
##
## The dock goes on editing its own settings while the thread runs — that is the point
## of the thread — and a stage reading them mid-run would see a value change underneath
## it. So the worker gets its own instances and its own settings, deep-copied through
## the sidecar codec, which already knows how to walk every nested resource these have.
func _snapshot_operation() -> IWOperation:
    return _snapshot_pipeline(_stack_view.stages())


## A pipeline of fresh stages carrying deep copies of [param stages]' settings.
func _snapshot_pipeline(stages: Array) -> IWPipeline:
    var pipeline := IWPipeline.new()
    for stage: IWStackOperation in stages:
        var script := stage.get_script()
        if script == null:
            continue
        var worker: IWStackOperation = script.new()
        worker.enabled = stage.enabled
        var live := stage.get_settings()
        if live != null:
            var copy := worker.make_settings()
            if copy != null:
                SettingsIO.apply_dict(copy, SettingsIO.to_dict(live))
                worker.set_settings(copy)
        pipeline.stages.append(worker)
    return pipeline


## Hands the preview both images, so the fade slider can move between them
## without anything being re-run.
##
## Before the first run there is no result, and the source stands in for it — the
## slider then has the same image on both sides and does nothing visible, which
## is the honest answer to fading between an image and itself.
func _update_preview_texture() -> void:
    if _source_image == null:
        _preview.set_image(null)
        _preview.set_original(null)
        return
    _preview.set_image(_result_image if _result_image != null else _source_image)
    _preview.set_original(_source_image)


## Right-clicking the dropdown swaps it for a text field, so a zoom that is not
## on the list can still be asked for by name.
func _on_zoom_select_input(event: InputEvent) -> void:
    var button := event as InputEventMouseButton
    if button == null or not button.pressed or button.button_index != MOUSE_BUTTON_RIGHT:
        return
    _zoom_select.accept_event()
    _begin_zoom_entry()


func _begin_zoom_entry() -> void:
    # Rounded, because it is a starting point to edit rather than a reading. The
    # exact value is only lost if the user accepts what is shown.
    _zoom_entry.text = "%d" % roundi(_preview.get_zoom())
    _zoom_select.hide()
    _zoom_entry.show()
    _zoom_entry.grab_focus()
    _zoom_entry.select_all()


## Applies whatever was typed and puts the dropdown back.
##
## Reached from Enter and from losing focus, and hiding a focused field raises
## focus_exited — so this has to be safe to call twice for one edit.
func _commit_zoom_entry(text: String) -> void:
    if not _zoom_entry.visible:
        return
    _end_zoom_entry()
    var cleaned := text.strip_edges().trim_suffix("%").strip_edges()
    if cleaned.is_valid_float():
        _preview.set_zoom(cleaned.to_float())
    # set_zoom clamps, and stays quiet when the value has not moved, so the
    # dropdown is rebuilt from the view rather than from what was typed.
    _refresh_zoom_items(_preview.get_zoom())


func _on_zoom_entry_input(event: InputEvent) -> void:
    var key := event as InputEventKey
    if key == null or not key.pressed or key.keycode != KEY_ESCAPE:
        return
    _zoom_entry.accept_event()
    _end_zoom_entry()
    _refresh_zoom_items(_preview.get_zoom())


func _end_zoom_entry() -> void:
    _zoom_entry.hide()
    _zoom_select.show()


func _on_zoom_selected(index: int) -> void:
    # The exact value rides in the metadata: the label is rounded for display,
    # and picking "15%" should restore the 14.65% Fit actually chose.
    _preview.set_zoom(_zoom_select.get_item_metadata(index))


func _on_zoom_changed(percent: float) -> void:
    _refresh_zoom_items(percent)


## Rebuilds the dropdown around [param percent] and selects it.
##
## The list is [constant PreviewView.ZOOM_STOPS], the same stops the buttons and
## the wheel step through. Fit can land between them, so a value that is not on
## the list gets a row of its own, in sorted position, for as long as the view
## sits there — the control has to be able to say what the zoom actually is, not
## merely the nearest thing it can offer.
func _refresh_zoom_items(percent: float) -> void:
    var values := PackedFloat32Array()
    var placed := false
    for stop in PreviewView.zoom_stops():
        if not placed and absf(stop - percent) < _ZOOM_MATCH:
            placed = true
        elif not placed and percent < stop:
            values.append(percent)
            placed = true
        values.append(stop)
    if not placed:
        values.append(percent)

    _zoom_select.clear()
    for i in values.size():
        # Rounded for display only; the view keeps the exact value, which matters
        # after Fit lands on something like 14.65%.
        _zoom_select.add_item("%d%%" % roundi(values[i]))
        _zoom_select.set_item_metadata(i, values[i])
        if absf(values[i] - percent) < _ZOOM_MATCH:
            # select() does not re-emit item_selected, so this cannot loop back
            # into _on_zoom_selected.
            _zoom_select.select(i)


## The status label ellipsises, so the full message is kept as its tooltip.
func _set_status(text: String) -> void:
    _status_label.text = text
    _status_label.tooltip_text = text


func _update_detail_label() -> void:
    if _source_image == null:
        _detail_label.text = ""
        return
    _detail_label.text = "%d x %d" % [_source_image.get_width(), _source_image.get_height()]


func _update_controls() -> void:
    var has_selection := _selected_index() >= 0
    var has_any := not _sources.is_empty()
    _remove_button.disabled = not has_selection
    _clear_button.disabled = not has_any
    _refresh_button.disabled = _source_image == null
    _process_selected_button.disabled = _source_image == null
    _process_all_button.disabled = not has_any


# --- Writing results ----------------------------------------------------

## Processing one image asks where to put it, so the Save As dialog carries the
## whole decision — no destination is remembered between runs.
func _on_process_selected() -> void:
    var index := _selected_index()
    if index < 0:
        return
    var path := _sources[index]
    _save_source = path
    _save_dialog.current_dir = path.get_base_dir()
    _save_dialog.current_file = _output_name_for(path)
    _save_dialog.popup_centered_ratio(0.6)


func _on_save_file_chosen(destination: String) -> void:
    var source := _save_source
    _save_source = ""
    if source.is_empty():
        return
    # FILE_MODE_SAVE_FILE has already asked about replacing an existing file, so
    # this goes straight to writing.
    _pending_outputs = {source: destination}
    _write_pending_outputs()


## Processing the whole list asks for a folder instead: one dialog cannot name
## every output, so the suffix does the naming and this only picks where.
func _on_process_all() -> void:
    if _sources.is_empty():
        return
    _output_dialog.current_dir = _sources[0].get_base_dir()
    _output_dialog.popup_centered_ratio(0.6)


func _on_output_dir_chosen(directory: String) -> void:
    # Sidecars travel with their image on the copy path, so they can be replaced by
    # a run too and belong in the warning below.
    var carries_sidecars := _mode == Mode.RENAME

    var jobs := {}
    var existing := PackedStringArray()
    for path in _sources:
        var destination := directory.path_join(_output_name_for(path))
        jobs[path] = destination
        if FileAccess.file_exists(destination):
            existing.append(destination.get_file())
        if not carries_sidecars or not FileAccess.file_exists(SettingsIO.sidecar_path(path)):
            continue
        # Only ours is listed: one belonging to something else is refused rather
        # than replaced, so naming it here would promise a write that never comes.
        var destination_sidecar := SettingsIO.sidecar_path(destination)
        if SettingsIO.is_sidecar(destination_sidecar):
            existing.append(destination_sidecar.get_file())

    _pending_outputs = jobs
    if existing.is_empty():
        _write_pending_outputs()
        return

    # No native prompt on a folder pick, so this names what would be replaced.
    var preview := existing
    var trailer := ""
    if existing.size() > 8:
        preview = existing.slice(0, 8)
        trailer = "\n... and %d more" % (existing.size() - 8)
    _overwrite_dialog.dialog_text = "These files already exist and will be replaced:\n\n%s%s" % [
        "\n".join(preview), trailer,
    ]
    _overwrite_dialog.popup_centered()


## Whether two paths name the same file on disk.
##
## Compared after globalising, because a source dragged from the FileSystem dock
## arrives as res:// while the destination comes back from a native dialog as an
## OS path — textually different, same file.
static func _is_same_file(a: String, b: String) -> bool:
    return ProjectSettings.globalize_path(a).simplify_path()  == ProjectSettings.globalize_path(b).simplify_path()


## Asks before deleting anything, naming how many and which.
func _confirm_source_removal() -> void:
    if _pending_removals.is_empty():
        return

    var names := PackedStringArray()
    for source: String in _pending_removals:
        names.append(source.get_file())
    var listed := names
    var trailer := ""
    if names.size() > 8:
        listed = names.slice(0, 8)
        trailer = "\n... and %d more" % (names.size() - 8)

    _removal_dialog.dialog_text = "Are you sure you want to remove %d file(s)?\n\n%s%s\n\nEach copy is checked against its source first, and they go to the trash." % [
        names.size(), "\n".join(listed), trailer,
    ]
    _removal_dialog.popup_centered()


## Proves every copy is byte-identical to its source, then trashes the sources.
##
## All or nothing on purpose. A partial delete after a partial verification is
## the worst outcome available here, so a single mismatch stops the lot.
func _verify_then_remove_sources() -> void:
    var candidates := _pending_removals
    _pending_removals = {}
    if candidates.is_empty():
        return

    # Two sources landing on one destination means the second overwrote the
    # first, and the first's original is now the only copy of it in existence.
    # Deleting on a checksum match would destroy it, because the survivor
    # matches its own source perfectly.
    var claimed := {}
    for source: String in candidates:
        var destination: String = candidates[source]
        if claimed.has(destination):
            _set_status("Nothing removed: %s and %s were both written to %s." % [
                String(claimed[destination]).get_file(), source.get_file(), destination.get_file(),
            ])
            push_warning("Image Wrangler: refused to remove sources, two of them share an output name.")
            return
        claimed[destination] = source

    var unverified := PackedStringArray()
    for source: String in candidates:
        var destination: String = candidates[source]
        if not FileAccess.file_exists(destination) or not FileAccess.file_exists(source):
            unverified.append(source.get_file())
            continue
        var source_hash := FileAccess.get_sha256(source)
        if source_hash.is_empty() or source_hash != FileAccess.get_sha256(destination):
            unverified.append(source.get_file())

    if not unverified.is_empty():
        _set_status("Nothing removed: %d copy/copies did not match their source: %s" % [
            unverified.size(), ", ".join(unverified),
        ])
        push_error("Image Wrangler: refused to remove sources, %s did not verify." % ", ".join(unverified))
        return

    var removed := 0
    var failures := PackedStringArray()
    # Only the ones that actually went get re-pointed below, so a file that
    # refused to move keeps its entry rather than being sent somewhere it isn't.
    var moved := {}
    for source: String in candidates:
        # Trash rather than unlink: the copy is verified, but the judgement that
        # the original is no longer wanted is the user's to reverse.
        if OS.move_to_trash(ProjectSettings.globalize_path(source)) == OK:
            removed += 1
            moved[source] = candidates[source]
        else:
            failures.append(source.get_file())

    _repoint_sources(moved)

    if failures.is_empty():
        _set_status("Removed %d original(s) to the trash; the Images list now points at the new files." % removed)
    else:
        _set_status("Removed %d original(s); %d could not be removed: %s" % [
            removed, failures.size(), ", ".join(failures),
        ])
        push_error("Image Wrangler: could not remove %s" % ", ".join(failures))

    if Engine.is_editor_hint():
        EditorInterface.get_resource_filesystem().scan()


## Points the Images list at the files that replaced the ones just removed.
##
## Only reached when originals were actually deleted, which is the only time an
## entry goes stale — a rename that left its sources alone has nothing to fix.
## Left unrepointed, selecting one of those rows would fail to load and a second
## run would skip it.
##
## [param moved] carries the sidecars that travelled alongside their images as
## well. They match nothing here — the list and the settings map are both keyed by
## image path — so they pass through without needing to be filtered out.
func _repoint_sources(moved: Dictionary) -> void:
    if moved.is_empty():
        return

    # Tracked by path rather than index, because the rebuild below can drop a row.
    var selected := _current_path()
    var rebuilt := PackedStringArray()
    for source in _sources:
        var path: String = moved[source] if moved.has(source) else source
        # A destination already in the list would otherwise appear twice.
        if not rebuilt.has(path):
            rebuilt.append(path)
        if source == selected:
            selected = path
    _sources = rebuilt

    # Per-image settings describe the image, so they follow it to its new path —
    # in memory here, and on disk as the sidecar copied during the run.
    for source: String in moved:
        if not _stacks_by_path.has(source):
            continue
        _stacks_by_path[moved[source]] = _stacks_by_path[source]
        _stacks_by_path.erase(source)

    # A pending write against the old path would resolve to nothing now.
    if moved.has(_autosave_path):
        _autosave_path = moved[_autosave_path]

    _refresh_file_list()
    var index := _sources.find(selected)
    if index >= 0:
        _file_list.select(index)
        # Reloads the image from its new path, so the preview is not left showing
        # a file that no longer exists.
        _on_file_selected(index)
    _update_controls()


## Output file name for a source, which the operation decides: a rename has a
## whole scheme to apply, where an image operation just keeps the name.
func _output_name_for(path: String) -> String:
    var active := _active_operation()
    if active == null:
        return path.get_file()
    var index := _sources.find(path)
    return active.get_output_name(path, _suffix_edit.text, maxi(index, 0))


## Sidecar paths that sources outside [param jobs] still read from.
##
## A sidecar is named from the basename alone, so [code]flower.png[/code] and
## [code]flower.jpg[/code] in one folder share [code]flower_wrangler.json[/code].
## Renaming only one of them must not carry that file away from the other, which
## would strip settings off an image this run never touched.
func _sidecars_held_outside(jobs: Dictionary) -> Dictionary:
    var held := {}
    for path in _sources:
        var source := String(path)
        if not jobs.has(source):
            held[SettingsIO.sidecar_path(source)] = true
    return held


## Copies a source's JSON counterpart alongside the copy of the image, and queues
## the original for the same removal check the image gets.
##
## The sidecar describes the image, so a rename that left it behind would strand
## every per-image setting the moment the dock was reopened — and, with Remove Old
## Files ticked, orphan it beside a file now in the trash. Whatever sits at the
## sidecar path travels, ours or not — the name is distinctive enough now that it
## almost certainly is ours, and a stranger's file named for this image belongs with
## it just as much.
##
## Returns the empty String when the sidecar was carried or there was none, and
## the name of the file left behind otherwise. Never fails the image: by the time
## this runs the image is already written, and reporting a rename as failed
## because of its sidecar would be a lie about what is on disk.
func _carry_sidecar(source_path: String, destination: String, held: Dictionary) -> String:
    var source_sidecar := SettingsIO.sidecar_path(source_path)
    if not FileAccess.file_exists(source_sidecar):
        return ""

    # Both sidecars are named from their image's basename, so a rename that only
    # changed the extension's case leaves them the same file. Copying it onto
    # itself would truncate it.
    var destination_sidecar := SettingsIO.sidecar_path(destination)
    if _is_same_file(source_sidecar, destination_sidecar):
        return ""

    # The one case where refusing beats writing: a JSON already at the new name
    # that this addon did not write is somebody else's, and a rename is no licence
    # to destroy it. Same judgement [method SettingsIO.save_settings] makes.
    if FileAccess.file_exists(destination_sidecar) and not SettingsIO.is_sidecar(destination_sidecar):
        return destination_sidecar.get_file()
    if DirAccess.copy_absolute(source_sidecar, destination_sidecar) != OK:
        return source_sidecar.get_file()

    # Queued on the same terms as the image — checksummed against its copy, all or
    # nothing with the rest, and to the trash rather than straight out. Held back
    # only when a source this run is not processing still reads it; the copy has
    # been made either way.
    if _removes_sources() and not held.has(source_sidecar):
        _pending_removals[source_sidecar] = destination_sidecar
    return ""


## Whether a source should be offered for deletion once its output is written.
##
## Only ever true for the file operation: anything that rewrites pixels has no
## business offering it, since its output is not a copy of anything.
func _removes_sources() -> bool:
    return _mode == Mode.RENAME and _rename != null and _rename.removes_sources()


## Runs the stack over every queued source and writes the results.
func _write_pending_outputs() -> void:
    var jobs := _pending_outputs
    _pending_outputs = {}
    if jobs.is_empty():
        return

    # A sidecar still sitting in the debounce is written now, so the copy carried
    # alongside a renamed image is the settings as they stand rather than as they were
    # a tick ago. The run itself reads from memory and would not have noticed.
    _flush_autosave()

    # Rename copies the file byte for byte rather than decoding and re-encoding it, so
    # a format this addon cannot write is not turned into a PNG wearing the wrong
    # extension.
    var rewrites_pixels := _mode != Mode.RENAME
    # Worked out once for the whole run rather than per file, since it depends on which
    # sources the run leaves alone.
    var held_sidecars := _sidecars_held_outside(jobs)

    var written := 0
    var failures := PackedStringArray()
    var sidecar_failures := PackedStringArray()
    for source_path: String in jobs:
        var destination: String = jobs[source_path]
        var directory := destination.get_base_dir()
        if not DirAccess.dir_exists_absolute(directory):
            var make_error := DirAccess.make_dir_recursive_absolute(directory)
            if make_error != OK:
                failures.append(source_path.get_file())
                continue

        if not rewrites_pixels:
            if source_path == destination or DirAccess.copy_absolute(source_path, destination) != OK:
                failures.append(source_path.get_file())
                continue
            written += 1
            # Only a candidate, and only because this one copy landed. Whether any of
            # them are actually deleted is decided after the whole run.
            if _removes_sources() and not _is_same_file(source_path, destination):
                _pending_removals[source_path] = destination
            # After the image, so a copy that failed leaves no sidecar stranded beside a
            # file that was never written.
            var stalled := _carry_sidecar(source_path, destination, held_sidecars)
            if not stalled.is_empty():
                sidecar_failures.append(stalled)
            continue

        var image := _load_image(source_path)
        if image == null:
            failures.append(source_path.get_file())
            continue
        # A fresh pipeline per job, built from that image's own saved stack. Nothing
        # the dock is showing is touched, which is what lets the form go on being
        # edited during a run and what stops one image's settings leaking into the
        # next — the old arrangement swapped them on the live operation and put them
        # back afterwards.
        var stages := []
        for record: Dictionary in _stack_for(source_path):
            var stage: IWStackOperation = record["operation"]
            stage.set_settings(record["settings"])
            stage.enabled = bool(record["enabled"])
            stages.append(stage)
        var result := _snapshot_pipeline(stages).process_image(image)
        if result.save_png(destination) != OK:
            failures.append(source_path.get_file())
            continue
        written += 1

    var report := "Wrote %d file(s)." % written
    if not failures.is_empty():
        report = "Wrote %d file(s), %d failed: %s" % [written, failures.size(), ", ".join(failures)]
        push_error("Image Wrangler: failed to process %s" % ", ".join(failures))
    # Appended rather than replacing the line: the image is what the run was for,
    # and a sidecar left behind must not read as a failed rename.
    if not sidecar_failures.is_empty():
        report += " %d settings file(s) stayed put: %s" % [sidecar_failures.size(), ", ".join(sidecar_failures)]
        push_warning("Image Wrangler: could not carry %s across; the original stays." % ", ".join(sidecar_failures))
    _set_status(report)

    if Engine.is_editor_hint():
        EditorInterface.get_resource_filesystem().scan()

    # Last, so the outcome of the run is already on screen when the question is
    # asked, and so a failed copy has had its chance to keep its source off the
    # list above.
    _confirm_source_removal()
