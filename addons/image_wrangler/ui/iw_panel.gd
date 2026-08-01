@tool
extends VBoxContainer

## The Image Wrangler main screen: pick images, tweak an operation, write results.

const SettingsBuilder := preload("res://addons/image_wrangler/ui/iw_settings_builder.gd")
const PreviewView := preload("res://addons/image_wrangler/ui/iw_preview_view.gd")
const IslandPicker := preload("res://addons/image_wrangler/ui/iw_island_picker.gd")
const ColorList := preload("res://addons/image_wrangler/ui/iw_color_list.gd")
const PolygonList := preload("res://addons/image_wrangler/ui/iw_polygon_list.gd")
const HSVList := preload("res://addons/image_wrangler/ui/iw_hsv_list.gd")
const BrushList := preload("res://addons/image_wrangler/ui/iw_brush_list.gd")
const ExcludeTilesList := preload("res://addons/image_wrangler/ui/iw_exclude_tiles.gd")
const SettingsIO := preload("res://addons/image_wrangler/core/iw_settings_io.gd")
const StackView := preload("res://addons/image_wrangler/ui/iw_stack_view.gd")
const HistoryView := preload("res://addons/image_wrangler/ui/iw_history_view.gd")

## Every [IWStackOperation] the stack can hold, in the order the dropdown offers them.
## Add new stack operations here.
##
## Alphabetical by the name the operation gives itself, and nothing else. Headings used
## to sort them by what they were for, which only helps if you already know which
## heading a thing lives under — and by name is the one order you can aim at without
## knowing anything.
##
## [code]icon[/code] names an entry in [code]ui/icons/[/code], which is a copy of the
## editor's own set. See [method IWToolButton.theme_icon].
const OPERATIONS := [
    {"script": "res://addons/image_wrangler/core/brush_edit_op.gd", "icon": &"Paint"},
    {"script": "res://addons/image_wrangler/core/denoise.gd", "icon": &"Blend"},
    {"script": "res://addons/image_wrangler/core/edge_cleanup.gd", "icon": &"Path2D"},
    {"script": "res://addons/image_wrangler/core/fill_pinholes.gd", "icon": &"Bucket"},
    {"script": "res://addons/image_wrangler/core/hsv_adjust.gd", "icon": &"ColorPicker"},
    {"script": "res://addons/image_wrangler/core/island_picker_op.gd", "icon": &"ColorPick"},
    {"script": "res://addons/image_wrangler/core/polygon_edit_op.gd", "icon": &"Polygon2D"},
    {"script": "res://addons/image_wrangler/core/random_hsv_tiles.gd", "icon": &"RandomNumberGenerator"},
    {"script": "res://addons/image_wrangler/core/refine_edges.gd", "icon": &"CurveEdit"},
    {"script": "res://addons/image_wrangler/core/remove_background.gd", "icon": &"Eraser"},
    {"script": "res://addons/image_wrangler/core/remove_crevice.gd", "icon": &"ToolTriangle"},
    {"script": "res://addons/image_wrangler/core/remove_lines.gd", "icon": &"Line2D"},
    {"script": "res://addons/image_wrangler/core/remove_minimum_area.gd", "icon": &"GPUParticles2D"},
    {"script": "res://addons/image_wrangler/core/smooth_blocks.gd", "icon": &"Grid"},
    {"script": "res://addons/image_wrangler/core/smooth_color.gd", "icon": &"Color"},
    {"script": "res://addons/image_wrangler/core/smooth_halos.gd", "icon": &"Gradient"},
    {"script": "res://addons/image_wrangler/core/exclude_tiles.gd", "icon": &"ListSelect"},
]


## Every operation script, for the places that only need to know which operations exist —
## the registry a sidecar is decoded against, and the sweep that names them.
static func operation_scripts() -> Array:
    var out := []
    for entry: Dictionary in OPERATIONS:
        out.append(entry["script"])
    return out

## What a fresh image's stack starts as, which is nothing.
##
## Every stage is a response to something a particular image did — a nook the flood could
## not get into, an island the border could not reach, an edge that came back harder than
## it went in — and an image that did none of those things does not want the stage that
## fixes it. Anything guessed at here starts every image carrying work nobody asked for,
## and makes the form a list of things to switch off rather than a list to reach for.
##
## Add what the image turns out to need; the dropdown is right there, and the order the
## rest want to go in is on their own entries.
const DEFAULT_STACK := []

## The file operation, which is not a stack operation and never will be: it does not
## touch pixels, and its settings describe the batch rather than any one image.
const RENAME_SCRIPT := "res://addons/image_wrangler/core/rename.gd"

## Packing is not a stack operation either, and for a different reason again: it does not
## take an image and give one back. It takes every image on the list and gives back one
## sheet, so there is nowhere in a per-image stack it could sit.
const PACKING_SCRIPT := "res://addons/image_wrangler/core/iw_packing.gd"

## Upscale is the third of these, and the only one that does take an image and give one
## back. It stays out of the stack anyway, for two reasons: it runs on what the stack
## produced rather than alongside it, and its settings describe the batch — one ratio for
## the whole run — where every stage's describe the image they are dialled in against.
const UPSCALE_SCRIPT := "res://addons/image_wrangler/core/upscale.gd"

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

const INDICATOR_TOOLTIP := """Draws the outlines that say what has been picked or drawn.

Islands get a dashed box round the pixels they reached; drawn regions
get their shape dashed in the same way. Both sit right on top of the
edges you are trying to judge, so turning them off is how you see the
result on its own.

On the Packing tab it lays a coloured patch under each sprite instead,
so you can see where one ends and the next begins — a packed sheet
cannot be read off itself, since the gap between two sprites looks the
same as the transparent margin around either of them.

It changes nothing about what is processed — only what is drawn over
the preview."""

## What a highlighted brush stroke is lit up in.
##
## The same yellow the preview picks a marker out in, so a selected row means one thing
## across the whole dock. Short of solid: it lies on top of the pixels that stroke changed,
## and those are what the row was clicked to look at.
const BRUSH_OVERLAY_COLOR := Color(1.0, 1.0, 0.2, 0.65)

const MAGENTA_TOOLTIP := """Lays solid magenta under the image instead of the checkerboard.

The checkerboard is two greys a shade apart, which is what makes it read
as backing — and also what hides a pixel at a tenth alpha. Magenta gives
that up to answer the other question: anything short of solid takes on
some of it, so a pinhole or a surviving fringe shows as colour rather
than having to be spotted.

Only under the image, so the margins still say where it ends. It changes
nothing about what is processed or what is written out."""

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

## How long the Packing tab waits after a change before rebuilding the sheet.
##
## Far longer than the preview's, because the work behind it is far larger: a packing runs
## every open image's whole stack, where a preview runs one image's. Dragging the width
## spinner would otherwise start a batch run per pixel travelled.
const PACKING_DEBOUNCE := 0.6

## How long the Export tab waits after a change before working the normal map out again.
##
## Much shorter than [constant PACKING_DEBOUNCE], because this is one pass over pixels that
## already exist rather than a run of every open image's stack — so a strength slider can
## follow the mouse instead of catching up after it stops.
const NORMAL_DEBOUNCE := 0.2

## How long the Upscale tab waits after a change before running the network again.
##
## The same as Packing's, and for the same reason — a spinner being dragged reports a change
## per pixel travelled, and each of these costs a whole stack plus a pass of a neural
## network. Above [constant UPSCALE_AUTO_PIXEL_LIMIT] it does not run automatically at all.
const UPSCALE_DEBOUNCE := 0.6

## Above this many pixels in the [i]result[/i], the Upscale tab stops previewing on its own.
##
## Judged on the output rather than the source, which is the difference that matters here: a
## small image at 32x is an enormous one, and the cost of the run follows the pixels coming
## out. Refresh still asks for it, which is how anything above the line gets looked at.
const UPSCALE_AUTO_PIXEL_LIMIT := 4_194_304

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

Save Current just suggests it, so you can still rename the file in
the Save As dialog. Save All applies it to every file without asking
again, which makes the suffix the only thing keeping the results
apart from the sources.

So take care when it is blank: each output then keeps its source's
own name, and pointing Save All at the folder the sources are in
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
## it autosaves, it processes pixels. Rename and Packing are the two that are not: one
## describes what the batch is called and the other makes a single sheet out of all of it,
## and neither has anything to do with whichever file happens to be highlighted. That line
## is drawn by [method _is_image_mode] rather than by testing for one tab by name, which is
## what every one of these did while Rename was the only tab on the far side of it.
##
## Upscale goes last because it comes last: it is the one tab whose input is what the others
## produced, and reading the strip left to right is then the order a batch actually goes
## through.
enum Mode { IMAGE, HISTORY, RENAME, PACKING, UPSCALE }

var _mode := Mode.IMAGE


## Whether [param mode] is one of the tabs that works on the highlighted image.
##
## Operations and History both are — they preview it, they autosave its stack, they process
## its pixels. Rename, Packing and Upscale are not, and everything that used to be spelled
## [code]!= Mode.RENAME[/code] meant this rather than that: it was only ever right while
## Rename was the one tab on the far side of the line, and adding a second would otherwise
## have meant finding every site again.
##
## [b]Upscale sits outside it despite showing the highlighted image[/b], which is worth
## saying because it looks like a counterexample. What this line separates is not "does a
## picture appear" but "whose settings are these": an image mode autosaves a sidecar for the
## file in front of it and records an undo step per edit, and a ratio held once for the batch
## has no business doing either.
static func _is_image_mode(mode: int) -> bool:
    return mode == Mode.IMAGE or mode == Mode.HISTORY


## The three operations that describe the batch rather than an image, held for the session.
## One set of settings each, no sidecar.
var _rename: IWOperation
var _packing: IWOperation
## Typed as itself rather than as the base the other two are, because the dock asks it
## things no operation answers — what ratio is dialled in, how large that makes the result,
## and whether the last run failed. Naming the subclass is what gets those checked.
var _upscale: Upscale

## The sheet Packing last built, shown in the viewport while its tab is up.
##
## Null until the button is pressed. Packing is not a preview that follows what you type —
## it runs every open image's whole stack, which is far too much to do on a keystroke — so
## it is asked for and then stands until asked again.
var _packing_image: Image

## Where every sprite landed on [member _packing_image], one [Rect2i] each in the order the
## sprites were found.
##
## Kept because the sheet cannot be asked: once the sprites are painted on there is nothing
## in the pixels that says where one ends and the next begins. This is what the lookup table
## is written out of, and it is kept whether or not that switch is on — it is a few dozen
## rectangles, and holding it means ticking the box does not mean packing again.
var _packing_rects: Array = []

## The normal map for the sheet on screen, or null when normals are switched off.
##
## Held rather than worked out twice, so the preview and the write path cannot disagree about
## what the map is.
var _packing_normal_image: Image

## What that map was worked out from, so a change to a setting it does not read costs
## nothing. See [method _packing_normal_signature].
var _packing_normal_key := ""

## Whether the preview is showing the normal map in place of the sheet.
var _showing_normals := false

## Whether a packing is running, so a change arriving mid-run cannot start a second on top
## of the first, and whether one asked for itself while that was true.
var _packing_running := false
var _packing_pending := false

## What the last packing was made from, as one string.
##
## Compared against the settings after each edit so that the switches which do not change
## the sheet — Create Lookup Table is the only one so far — do not run every open image's
## whole stack again for a sheet that would come out identical.
var _packing_sheet_key := ""

## The highlighted image, run through its stack and then through waifu2x, shown in the
## viewport while the Upscale tab is up.
##
## Only ever the one image, where Packing does the whole list. The tab processes the whole
## list too — that is what Save All does — but a preview of it would be a run of the network
## per file for a picture that can only show one of them.
var _upscale_image: Image

## Which source [member _upscale_image] was made from.
##
## [b]The Image object itself, which is the exact test.[/b] Selecting another file replaces
## it and nothing else does — the same identity check a finished preview is kept or dropped
## by. It matters because the tab can be left and come back to: without it, tabbing away,
## clicking a different file and tabbing back would show the previous file's result until
## the rerun landed, which is a picture presented as this file's when it is not.
var _upscale_source: Image

## The network's answer before Sharpen was applied to it, and what it was made from.
##
## [b]Kept so that moving the Sharpen slider does not run the network again.[/b] Sharpen is
## a remap of the finished picture and changes nothing the network did, so re-running it
## would spend seconds arriving at pixels already on hand. [member _upscale_raw_key] is
## [method Upscale.network_signature] — every setting that does not survive the slider —
## and the source is compared by identity, exactly as [member _upscale_source] is.
var _upscale_raw: Image
var _upscale_raw_source: Image
var _upscale_raw_key := ""

## Whether an upscale is running, so a change arriving mid-run cannot start a second on top
## of the first, and whether one asked for itself while that was true.
var _upscale_running := false
var _upscale_pending := false

## Why the upscaler could not run during a Save All, held for the report at the end of it.
## See [method _processed_image].
var _upscale_failure := ""

## Set between asking where to put the packed sheet and being told, so the one file dialog
## the dock has knows which of its two callers it is answering.
var _saving_sheet := false
var _sources: PackedStringArray = PackedStringArray()
var _source_image: Image
var _result_image: Image

## The live brush's working copy of what is on screen, and the state of the drag painting
## into it.
##
## [b]Held for the length of one drag and thrown away at the end of it.[/b] A stroke cannot
## wait for the stack to re-run between two mouse events, so the paint goes straight onto
## the composed pixels here and the real run replaces the lot when the button comes up.
##
## [member _paint_base] is the untouched picture and [member _paint_strength] is how hard
## the stroke has hit each pixel so far. Every patch is worked out from those two rather
## than from the last one, so that a soft brush overlapping its own rim a dozen times along
## a stroke stays soft. [member _paint_image] is only where the patches are kept, for the
## upload and for the hand-off at the end.
##
## [member _paint_beneath] is the source at the same size, for the colour Add needs where
## it lifts a pixel out of full transparency — there is nothing meaningful in the composed
## image at such a pixel. Built only for an Add stroke, since Subtract never asks.
##
## [member _paint_bounds] is everything the stroke has reached so far, which is what gets
## uploaded. It grows with the stroke and no faster, which is the point: the cost of a drag
## is the area it covers rather than the size of the sheet.
var _paint_image: Image
var _paint_base: Image
var _paint_strength: Image
var _paint_beneath: Image
var _paint_bounds := Rect2i()
var _paint_at := Vector2i(-1, -1)
var _paint_radius := 1
var _paint_sharpness := 1.0
var _paint_adding := false

## Whether a run is in flight.
##
## A run sits between two stages while the editor goes on painting, and the editor is
## live enough in that gap for the debounce to fire and ask for another.
var _preview_running := false

## Whether something asked for a preview while one was already running, which also
## means whatever comes back from that run is out of date.
var _preview_pending := false

## Set while the dock is leaving the tree, and checked by everything a run reports
## back through.
##
## A run yields between stages, so the dock can be pulled out from under one that is
## halfway along. These guards are what stop the rest of it writing into controls that
## are on their way out.
var _shutting_down := false

## The operation the current run is working through, kept so it can be told to stop.
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

## Which groups inside a settings form are folded, keyed by the form and the group.
##
## Only the groups within a form. Whether a whole stack entry is folded lives on the
## operation, beside whether it is enabled, and is saved with it.
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
var _packing_box: VBoxContainer
## Says how the last packing went — how many sprites off how many images, or why it stopped.
var _packing_status: Label
## Says what the selected packing mode does, sitting under the dropdown and above the rest
## of the form.
var _packing_mode_note: Label
## The same, for the normals dropdown further down the form.
var _packing_normal_note: Label
## Swaps the preview between the sheet and the normal map made from it.
var _packing_normal_toggle: CheckBox
var _upscale_box: VBoxContainer
## Says how the last upscale went, or why it could not run at all.
var _upscale_status: Label
## Says what the selected model is for, sitting under its dropdown.
var _upscale_model_note: Label
## How much of the source image is faded over the result, 0 to 100.
var _original_fade: HSlider
var _zoom_select: OptionButton
var _zoom_entry: LineEdit
var _indicator_choice: OptionButton

## How much of the stack's marks are drawn.
enum Indicators {
    ## Every operation's, all at once.
    ALL,
    ## None at all, so the result can be judged on its own.
    NONE,
    ## Only the operation the stack is pointed at.
    SELECTED,
}

const INDICATOR_LABELS := ["All", "None", "Selected"]

## Which of those is in force.
var _indicators := Indicators.ALL
var _magenta_toggle: CheckBox
var _refresh_button: Button
var _remove_button: Button
var _clear_button: Button
var _suffix_edit: LineEdit
var _process_selected_button: Button
var _process_all_button: Button
var _debounce: Timer
var _packing_debounce: Timer
var _packing_normal_debounce: Timer
var _upscale_debounce: Timer
var _autosave: Timer
var _open_dialog: FileDialog
var _output_dialog: FileDialog
var _save_dialog: FileDialog

## Which source a pending Save As belongs to, held between opening the dialog
## and the user choosing a name.
var _save_source := ""
var _overwrite_dialog: ConfirmationDialog
var _removal_dialog: ConfirmationDialog
## Says a packing ran out of room. An AcceptDialog rather than a Confirmation: there is
## nothing to agree to, since the run has already stopped.
var _packing_dialog: AcceptDialog
var _reset_dialog: ConfirmationDialog
var _stack_save_dialog: FileDialog
var _stack_load_dialog: FileDialog

## The right-click menu over the stack, and what the choice on it would act on.
##
## Rebuilt every time it opens, because what it can offer depends on what is on the
## clipboard this instant.
var _stack_menu: PopupMenu
var _stack_menu_index := -1
var _stack_menu_at := 0

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
    _build_packing()
    _build_upscale()
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
## Ctrl+Z and Ctrl+Shift+Z walk this image's history, one step up or down the list the
## History tab shows.
##
## Ctrl+Shift+R rebuilds the interface, which is a development affordance rather than
## a feature: see [method _rebuild_ui]. It takes a modifier so it cannot be hit by
## accident, and being scoped to the dock like the rest, it leaves the combination free
## everywhere else in the editor.
func _unhandled_key_input(event: InputEvent) -> void:
    if _preview == null or not is_visible_in_tree():
        return
    var key := event as InputEventKey
    if key == null or not key.pressed:
        return
    if not get_global_rect().has_point(get_global_mouse_position()):
        return

    # Ahead of the repeat guard below, because holding these two is how anyone walks back
    # more than a step or two and refusing to repeat would make that twenty presses.
    if key.keycode == KEY_Z and key.ctrl_pressed and not key.alt_pressed \
            and not key.meta_pressed:
        # A rename scheme has no history, so the keystroke is left for whoever wants it
        # rather than swallowed to do nothing.
        if not _is_image_mode(_mode):
            return
        accept_event()
        _step_history(1 if key.shift_pressed else -1)
        return

    if key.echo:
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

    # Escape puts the brush away. Unlike the polygon it does not wait for a shape to be
    # open: a stroke is finished the moment the button comes up, so a brush with no draft
    # is the ordinary state to be in while still holding the tool.
    if _painting_list() != null and key.keycode == KEY_ESCAPE:
        _finish_painting()
        accept_event()
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
## A run in flight is told to stop here as well. It cannot be waited on — it is parked on
## a frame that has not come yet — so cancelling is what ends it: it resumes, finds the
## flag at its next checkpoint and drops out without reporting.
func _exit_tree() -> void:
    _shutting_down = true

    var filesystem := EditorInterface.get_resource_filesystem()
    if filesystem != null and filesystem.resources_reload.is_connected(_on_resources_reload):
        filesystem.resources_reload.disconnect(_on_resources_reload)

    _flush_autosave()
    _preview_pending = false
    if _preview_worker_op != null:
        _preview_worker_op.cancelled = true
    _preview_worker_op = null
    # Cleared so the way is open for the next run should the dock come back.
    _preview_running = false

    # Hands back the Vulkan device and the several hundred megabytes of video memory the
    # model is sitting in. Nothing else here holds anything the editor would miss, and the
    # editor goes on running after the dock has gone.
    if _upscale != null:
        _upscale.close()


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


## The same, for the other operation that belongs to the batch rather than to an image.
func _build_packing() -> void:
    if _packing == null:
        var script: GDScript = load(PACKING_SCRIPT)
        if script == null:
            push_error("Image Wrangler: could not load operation script at %s" % PACKING_SCRIPT)
            return
        _packing = script.new()
    SettingsBuilder.build(_packing, _packing_box, _on_setting_changed, _fold_state, "packing")

    # The note goes under the dropdown rather than at the top or the bottom of the form,
    # because it is about the one control above it and not about the sheet size below.
    # Moved into place rather than declared in the schema: the builder lays out settings,
    # and a line of prose is not one — it has no property to write and nothing to read
    # back, and giving the schema a way to say "and now some words" would be a new kind of
    # entry for every other operation to ignore.
    #
    # The mode note goes first, so the search for the normals row sees the row it added and
    # lands under that dropdown rather than one above it.
    _place_packing_note(_packing_mode_note, &"mode")
    _place_packing_note(_packing_normal_note, &"normals")
    _refresh_packing_note()
    _packing_sheet_key = _packing_sheet_signature()
    _packing_normal_key = _packing_normal_signature()
    _update_normal_toggle()


## Puts [param note] directly under whichever row carries [param property].
func _place_packing_note(note: Label, property: StringName) -> void:
    if note == null:
        return
    if note.get_parent() != null:
        note.get_parent().remove_child(note)
    _packing_box.add_child(note)
    _packing_box.move_child(note, _packing_note_index(property))


## Where a note belongs: directly after whichever row carries [param property].
##
## Found rather than counted, so reordering the schema moves the note with it. Falls to the
## top of the form if the row cannot be found at all, which is the harmless place for a line
## of prose to end up.
func _packing_note_index(property: StringName) -> int:
    for child in _packing_box.get_children():
        if child.has_meta(SettingsBuilder.META_PROPERTY) \
                and child.get_meta(SettingsBuilder.META_PROPERTY) == property:
            return child.get_index() + 1
    return 0


func _refresh_packing_note() -> void:
    if _packing == null:
        return
    var settings := _packing.get_settings()
    if _packing_mode_note != null:
        _packing_mode_note.text = IWPacking.describe_mode(settings.mode)
    if _packing_normal_note != null:
        _packing_normal_note.text = _packing.describe_normals(settings.normals)


## The third of these, for the tab that runs the network.
##
## The model dropdown is filled from what is on disk rather than from a list in code, so the
## form is rebuilt here on every rebuild — a model folder added while the dock was open
## appears the next time this runs.
func _build_upscale() -> void:
    # Before the operation is made, so a first build and a rebuild both see the disk as it
    # is now — the dropdown is filled from this and the default model is chosen from it.
    Upscale.refresh_models()
    if _upscale == null:
        var script: GDScript = load(UPSCALE_SCRIPT)
        if script == null:
            push_error("Image Wrangler: could not load operation script at %s" % UPSCALE_SCRIPT)
            return
        _upscale = script.new()
    # Before the form is built, so the Model and Scale dropdowns are filled from the engine
    # the settings actually name. See Upscale.sync_engine.
    _upscale.sync_engine()
    _upscale_form_key = _upscale_form_signature()
    SettingsBuilder.build(_upscale, _upscale_box, _on_setting_changed, _fold_state, "upscale")

    # Under the model dropdown for the same reason Packing's note sits under its mode
    # dropdown: it is about the one control above it. See _build_packing.
    if _upscale_model_note != null:
        if _upscale_model_note.get_parent() != null:
            _upscale_model_note.get_parent().remove_child(_upscale_model_note)
        _upscale_box.add_child(_upscale_model_note)
        _upscale_box.move_child(_upscale_model_note, _upscale_note_index())
    _refresh_upscale_note()

    # Said on the way in rather than waiting for the first run to fail. A build without the
    # native class is the ordinary state of a fresh checkout, and a form full of settings
    # over a viewport that never fills is the worst way to find that out.
    var blocked := _upscale_blocked()
    if not blocked.is_empty():
        _set_upscale_status(blocked)
    elif not Upscale.gpu_available():
        _set_upscale_status("No Vulkan device found, so this will run on the processor. Expect minutes rather than seconds.")


## What the Upscale form was built for, so a settings change that changes the form itself is
## noticed. See [method _upscale_form_signature].
var _upscale_form_key := ""


## The two settings that decide what the Upscale form looks like rather than what it does.
##
## [b]Both change the options in a dropdown, which nothing else would follow.[/b] The engine
## swaps the model list for another one and takes the Denoise row away; the model decides
## which ratios Real-ESRGAN can offer, since each of its folders ships the networks it
## ships. Every other setting only changes a value, and the form can carry on as it is.
func _upscale_form_signature() -> String:
    if _upscale == null:
        return ""
    return "%d|%s" % [_upscale.engine(), _upscale.model_name()]


## Where the model note belongs: directly after the row carrying the model dropdown. Found
## rather than counted, so reordering the schema moves the note with it.
func _upscale_note_index() -> int:
    for child in _upscale_box.get_children():
        if child.has_meta(SettingsBuilder.META_PROPERTY) \
                and child.get_meta(SettingsBuilder.META_PROPERTY) == &"model_index":
            return child.get_index() + 1
    return 0


func _refresh_upscale_note() -> void:
    if _upscale_model_note == null or _upscale == null:
        return
    _upscale_model_note.text = _upscale.model_description()


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

    # A run in flight reports into controls that are about to be freed. Cancelled exactly
    # as [method _exit_tree] does it: it cannot be waited on, but the cancel reaches it at
    # its next checkpoint and what it reports then lands on the rebuilt controls
    # harmlessly.
    _preview_pending = false
    if _preview_worker_op != null:
        _preview_worker_op.cancelled = true
    _preview_worker_op = null
    _preview_running = false

    var path := _current_path()
    var selected := _selected_index()
    var mode := _mode
    var suffix := _suffix_edit.text
    var fade := _original_fade.value
    var zoom := _preview.get_zoom()
    var indicators := _indicators
    var magenta := _preview.magenta_background
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
    _build_packing()
    _build_upscale()

    _indicators = indicators
    _preview.markers_visible = _indicators != Indicators.NONE
    _indicator_choice.selected = _indicators
    _preview.magenta_background = magenta
    _magenta_toggle.set_pressed_no_signal(magenta)
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
    _packing_box = null
    _packing_status = null
    _packing_mode_note = null
    _packing_normal_note = null
    _packing_normal_toggle = null
    _upscale_box = null
    _upscale_status = null
    _upscale_model_note = null
    _original_fade = null
    _zoom_select = null
    _zoom_entry = null
    _indicator_choice = null
    _magenta_toggle = null
    _refresh_button = null
    _remove_button = null
    _clear_button = null
    _suffix_edit = null
    _process_selected_button = null
    _process_all_button = null
    _debounce = null
    _packing_debounce = null
    _packing_normal_debounce = null
    _upscale_debounce = null
    _autosave = null
    _open_dialog = null
    _output_dialog = null
    _save_dialog = null
    _overwrite_dialog = null
    _removal_dialog = null
    _packing_dialog = null


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

    _packing_debounce = Timer.new()
    _packing_debounce.one_shot = true
    _packing_debounce.wait_time = PACKING_DEBOUNCE
    _packing_debounce.timeout.connect(_run_packing_now)
    add_child(_packing_debounce)

    _packing_normal_debounce = Timer.new()
    _packing_normal_debounce.one_shot = true
    _packing_normal_debounce.wait_time = NORMAL_DEBOUNCE
    _packing_normal_debounce.timeout.connect(_rebuild_packing_normals)
    add_child(_packing_normal_debounce)

    _upscale_debounce = Timer.new()
    _upscale_debounce.one_shot = true
    _upscale_debounce.wait_time = UPSCALE_DEBOUNCE
    # Bound rather than connected bare: a timeout carries no arguments, and the run wants
    # to know it was not asked for by Refresh.
    _upscale_debounce.timeout.connect(_run_upscale_now.bind(false))
    add_child(_upscale_debounce)

    _autosave = Timer.new()
    _autosave.one_shot = true
    _autosave.wait_time = AUTOSAVE_DEBOUNCE
    _autosave.timeout.connect(_flush_autosave)
    add_child(_autosave)


## Nothing is reprocessed: the overlays are drawn over the result rather than into it, so
## this is a repaint and not a rerun.
##
## None switches the whole overlay off at the preview; Selected leaves it on and lets
## [method _update_overlays] hand over one operation's marks instead of the stack's.
func _on_indicators_chosen(index: int) -> void:
    _indicators = index if index >= 0 and index < INDICATOR_LABELS.size() else Indicators.ALL
    if _preview != null:
        _preview.markers_visible = _indicators != Indicators.NONE
    _update_overlays()


## Nothing is reprocessed either: the ground is drawn under the result rather than into
## it, so what gets written out is untouched.
func _on_magenta_toggled(pressed: bool) -> void:
    if _preview != null:
        _preview.magenta_background = pressed


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
    # but this is a switch you want in sight while judging an edge, not one to go
    # hunting for. The overlays sit right on top of what they describe, so getting
    # them out of the way has to be quick.
    var indicator_label := Label.new()
    indicator_label.text = "Indicators"
    indicator_label.tooltip_text = INDICATOR_TOOLTIP
    toolbar.add_child(indicator_label)

    _indicator_choice = OptionButton.new()
    _indicator_choice.tooltip_text = INDICATOR_TOOLTIP
    for label: String in INDICATOR_LABELS:
        _indicator_choice.add_item(label)
    _indicator_choice.selected = Indicators.ALL
    _indicator_choice.item_selected.connect(_on_indicators_chosen)
    toolbar.add_child(_indicator_choice)

    # Beside the indicator switch because the two are the same kind of control — neither
    # touches the result, both change what you are looking at while judging it. The second
    # long label on this toolbar, and it widens the preview column's minimum again for the
    # same reason that one does: a switch you reach for mid-judgement has to be in sight.
    _magenta_toggle = CheckBox.new()
    _magenta_toggle.text = "Magenta Background"
    _magenta_toggle.tooltip_text = MAGENTA_TOOLTIP
    _magenta_toggle.button_pressed = false
    _magenta_toggle.toggled.connect(_on_magenta_toggled)
    toolbar.add_child(_magenta_toggle)

    var spacer := Control.new()
    spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    toolbar.add_child(spacer)

    _refresh_button = Button.new()
    _refresh_button.text = "Refresh"
    _refresh_button.tooltip_text = "Re-run the operation on the selected image."
    _refresh_button.pressed.connect(_on_refresh_pressed)
    toolbar.add_child(_refresh_button)

    _preview = PreviewView.new()
    _preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _preview.pixel_picked.connect(_on_pixel_picked)
    _preview.region_picked.connect(_on_region_picked)
    _preview.stroke_point.connect(_on_stroke_point)
    _preview.stroke_finished.connect(_on_stroke_finished)
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
    # A floor for the contents rather than for the tab strip, which sets its own below and
    # is very likely the larger of the two. It still matters if the tabs are ever renamed
    # shorter: a settings form has a width it stops being usable under, and that width has
    # nothing to do with how the strip above it happens to read.
    column.custom_minimum_size = Vector2(220, 0)

    # Tabs rather than toggles, because the two are not settings of one thing: one
    # rewrites pixels and the other rewrites names, and only one of them is ever what
    # a Process button is about to do. A tab says "you are in here" in a way two
    # pressed-looking buttons do not.
    _modes = TabContainer.new()
    _modes.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _modes.tab_changed.connect(_on_tab_changed)
    # [b]The strip is what sets this column's minimum width.[/b] Left to clip, a TabBar
    # reports a minimum of almost nothing and hides whatever does not fit behind scroll
    # arrows — so the column could be dragged narrow enough that Packing and Rename were
    # only reachable by scrolling a strip of four short words. Refusing to clip makes the
    # bar report what it actually needs, and a container's minimum is its children's, so
    # the splitter stops where the last tab does.
    #
    # Measured rather than written down as a number: the answer depends on the editor's
    # font and scale, and on how many tabs there are. A fifth one widens this by itself.
    _modes.get_tab_bar().clip_tabs = false
    column.add_child(_modes)

    # Each tab gets its own scroll, so switching does not carry the other one's scroll
    # position across. Operations keeps its own rather than being handed one here: the
    # tools and the Add dropdown at the top of it must not scroll away with the stack, so
    # the scroll starts under them. See iw_stack_view.gd.
    _stack_view = StackView.new()
    # The tab strip takes its label from the node's name.
    _stack_view.name = "Operations"
    _stack_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _stack_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _stack_view.operations = OPERATIONS
    _stack_view.form_builder = _build_entry_form
    _stack_view.stack_changed.connect(_on_stack_changed)
    _stack_view.setting_changed.connect(_on_setting_changed)
    _stack_view.fold_changed.connect(_on_fold_changed)
    # Only matters while the marks are showing one operation's worth, but redrawing when
    # they are not costs a pass over an overlay nobody is looking at.
    _stack_view.selection_changed.connect(_update_overlays)
    _stack_view.entries_rebuilt.connect(_on_entries_rebuilt)
    _stack_view.copy_requested.connect(_on_copy_stack)
    _stack_view.paste_requested.connect(_on_paste_stack)
    _stack_view.save_requested.connect(_on_save_stack)
    _stack_view.load_requested.connect(_on_load_stack)
    _stack_view.reset_requested.connect(_on_reset_stack)
    _stack_view.menu_requested.connect(_on_stack_menu)
    _modes.add_child(_stack_view)

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

    var packing_page := ScrollContainer.new()
    packing_page.name = "Export"
    packing_page.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    _modes.add_child(packing_page)

    var packing_column := VBoxContainer.new()
    packing_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    packing_page.add_child(packing_column)

    _packing_box = VBoxContainer.new()
    _packing_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    packing_column.add_child(_packing_box)

    # Says what the mode in the dropdown above it does. Built here and moved into the form
    # by _build_packing, which is the only thing that knows where the dropdown ended up.
    _packing_mode_note = Label.new()
    _packing_mode_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _packing_mode_note.modulate = Color(1, 1, 1, 0.6)

    # The same for the normals dropdown, which needs one more than the packing mode does:
    # the three that work read different things about the sprite, and the names alone do not
    # say which suits the art in front of you.
    _packing_normal_note = Label.new()
    _packing_normal_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _packing_normal_note.modulate = Color(1, 1, 1, 0.6)

    # Outside _packing_box on purpose. The settings builder frees everything in that box
    # every time it runs, and this has to outlive a rebuild of the form.
    _packing_normal_toggle = CheckBox.new()
    _packing_normal_toggle.text = "Show Normal Map"
    _packing_normal_toggle.tooltip_text = "Shows the normal map in place of the sheet, so it can be tuned before it is\nwritten.\n\nThe fade slider brings the sheet back over it. The two line up pixel for pixel,\nwhich is the only way to tell whether the rounding is following the art."
    _packing_normal_toggle.toggled.connect(_on_show_normals_toggled)
    packing_column.add_child(_packing_normal_toggle)

    _packing_status = Label.new()
    _packing_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _packing_status.modulate = Color(1, 1, 1, 0.6)
    packing_column.add_child(_packing_status)

    var upscale_page := ScrollContainer.new()
    upscale_page.name = "Upscale"
    upscale_page.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    _modes.add_child(upscale_page)

    var upscale_column := VBoxContainer.new()
    upscale_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    upscale_page.add_child(upscale_column)

    _upscale_box = VBoxContainer.new()
    _upscale_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    upscale_column.add_child(_upscale_box)

    # Says what the model in the dropdown above it is for. Built here and moved into the
    # form by _build_upscale, exactly as Packing's note is.
    _upscale_model_note = Label.new()
    _upscale_model_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _upscale_model_note.modulate = Color(1, 1, 1, 0.6)

    _upscale_status = Label.new()
    _upscale_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _upscale_status.modulate = Color(1, 1, 1, 0.6)
    upscale_column.add_child(_upscale_status)

    _modes.set_tab_tooltip(Mode.IMAGE, "Build a stack of operations that rewrite the pixels.")
    _modes.set_tab_tooltip(Mode.HISTORY,
            "Every edit made to this image's stack this session.\nClick one to rewind to it. Held in memory only, and never saved.")
    _modes.set_tab_tooltip(Mode.RENAME,
            "Write the files out under new names, pixels untouched.\nDescribes the whole batch rather than one image, so it is not part of the stack.")
    _modes.set_tab_tooltip(Mode.PACKING,
            "Lay the objects from every open image out on one sheet.\nShown in the viewport; Save Current writes it.")
    _modes.set_tab_tooltip(Mode.UPSCALE,
            "Enlarge every open image with waifu2x, which invents the pixels\nrather than stretching them. Runs on what each image's stack made,\nnot on the file it came from.")

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
    if _is_image_mode(previous) != _is_image_mode(mode):
        _result_image = null
    _update_preview_texture()
    _update_detail_label()
    if _is_image_mode(mode) and _auto_preview_allowed():
        _schedule_preview()
    # Arriving on the tab is itself a reason to build one: an empty viewport under a form
    # full of settings reads as a tool that has not worked rather than one that has not
    # been asked.
    if mode == Mode.PACKING:
        _schedule_packing()
    elif mode == Mode.UPSCALE:
        # The kept network answer was made from the stack as it stood, and the stack can
        # only have been edited while another tab was up — so arriving here is exactly when
        # it stops being trustworthy.
        _upscale_raw = null
        _schedule_upscale()
    # Which of the two Save buttons has anything to do depends on the tab, so the switch
    # itself has to say so — nothing else runs on the way in.
    _update_controls()


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

    # Side by side rather than stacked. They are the same kind of action on the same
    # things, and a column of two full-width buttons reads as two unrelated decisions.
    var save_row := HBoxContainer.new()
    section.add_child(save_row)

    _process_selected_button = Button.new()
    _process_selected_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _process_selected_button.text = "Save Current"
    _process_selected_button.tooltip_text = "Process the selected image and ask where to save it.

On the Packing tab it saves the packed sheet instead, which is the one
thing there is to save there — plus the lookup table beside it, if that
switch is on. On Upscale it runs the image's operations and then the
network, which is what the tab is showing."
    _process_selected_button.pressed.connect(_on_process_selected)
    save_row.add_child(_process_selected_button)

    _process_all_button = Button.new()
    _process_all_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _process_all_button.text = "Save All"
    _process_all_button.tooltip_text = "Process every image in the list and ask for a folder to put them in.

Nothing to do on the Packing tab, where the whole list makes one sheet —
use Save Current for that.

On Upscale it runs every image through its own operations and then the
network. That is the slow one: it holds the editor for as long as it
takes, and it reports nothing until it is done."
    _process_all_button.pressed.connect(_on_process_all)
    save_row.add_child(_process_all_button)

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
    _output_dialog.title = "Save All Into Folder"
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
    # Cleared on the way out as well as on the way through: the flag says which of the two
    # callers the dialog is answering, and one left set by a cancel would send the next
    # ordinary save down the packed-sheet path.
    _save_dialog.canceled.connect(func() -> void: _saving_sheet = false)
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

    _packing_dialog = AcceptDialog.new()
    _packing_dialog.title = "Not Enough Room"
    add_child(_packing_dialog)

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

    _stack_menu = PopupMenu.new()
    _stack_menu.id_pressed.connect(_on_stack_menu_chosen)
    add_child(_stack_menu)

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


## Rewrites the Images list, and asks for a packing.
##
## [b]Every path that changes what is open ends here[/b] — adding, removing, clearing — so
## it is the one place that has to know a sheet made from those images is now out of date.
## Hooking the three of them separately would be three chances to add a fourth and forget.
func _refresh_file_list() -> void:
    _schedule_packing()
    _schedule_upscale()
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
        _blank_preview()
        _clear_stack()
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
    _blank_preview()
    _clear_stack()
    _set_status("No image selected.")
    _detail_label.text = ""
    _update_controls()


## Leaves the preview showing nothing at all.
##
## Every channel, not only the picture. A packed sheet outlives the files it was made
## from, since packing hangs on to what it built, and clearing the image alone would leave
## it on screen with nothing behind it — and the marks would sit over the empty
## checkerboard describing an image that has gone.
func _blank_preview() -> void:
    _forget_packed_sheet()
    _upscale_image = null
    _upscale_source = null
    _preview.set_image(null)
    _preview.set_original(null)
    _preview.set_tile_bounds([])
    _preview.set_markers([] as Array[Rect2i], -1)
    _preview.set_polygons([], -1, -1)
    _preview.set_ghosts([], [])
    _push_brush_overlay(null)


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
    if _mode == Mode.UPSCALE:
        # The tab shows whichever image is highlighted, so moving the highlight is a
        # reason to run it — the same reason changing a setting is.
        _schedule_upscale()
    elif _auto_preview_allowed():
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
    # Measured against the list rather than against this one path, so the dropdown is dead
    # from the moment the dock opens until the first image arrives.
    _stack_view.set_can_add(not _sources.is_empty())
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
    elif control is HSVList:
        var hsv := control as HSVList
        hsv.pick_toggled.connect(_on_pick_toggled.bind(hsv))
        hsv.regions_changed.connect(_on_setting_changed)
        hsv.selection_changed.connect(_on_selection_changed.bind(hsv))
    elif control is BrushList:
        var brush := control as BrushList
        brush.draw_toggled.connect(_on_pick_toggled.bind(brush))
        brush.strokes_changed.connect(_on_setting_changed)
        brush.selection_changed.connect(_on_selection_changed.bind(brush))
    elif control is ExcludeTilesList:
        var tiles := control as ExcludeTilesList
        tiles.pick_toggled.connect(_on_pick_toggled.bind(tiles))
        tiles.tiles_changed.connect(_on_setting_changed)
        tiles.selection_changed.connect(_on_selection_changed.bind(tiles))


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


## An entry was folded or unfolded.
##
## Written and nothing more. A fold moves no pixels, so it must not enter the undo history
## or start another run — it only has to reach the sidecar, so the stack is still tidy when
## the image is opened again.
func _on_fold_changed() -> void:
    if not _is_image_mode(_mode):
        return
    _store_stack(_current_path())
    _schedule_autosave()


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


## Moves one step through this image's history. [param direction] is -1 to undo and 1 to
## redo, which is up and down the list the History tab shows.
##
## The status line names where it landed, because the keyboard gives no other sign of it:
## the History tab moves its selection, and that is behind a tab the user is very likely
## not looking at while pressing this.
func _step_history(direction: int) -> void:
    var path := _current_path()
    if path.is_empty() or not _history_by_path.has(path):
        _set_status("Select an image to undo anything.")
        return

    var history: IWHistory = _history_by_path[path]
    var target := history.current_index() + direction
    if target < IWHistory.BASE_INDEX or target >= history.size():
        _set_status("Nothing left to undo." if direction < 0 else "Nothing left to redo.")
        return

    _on_history_revert(target)

    # Row zero is the state the image opened in, so a command's own row is one further
    # along than its index.
    var rows := history.rows()
    var landed: String = rows[target + 1]["label"]
    _set_status("%s: %s" % ["Undo" if direction < 0 else "Redo", landed])


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
        for script_path: String in operation_scripts():
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
            "folded": stage.folded,
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


## Puts whatever stack is on the clipboard in place of this one.
func _on_paste_stack() -> void:
    var stages := _stages_from_text(DisplayServer.clipboard_get())
    if stages.is_empty():
        _set_status("Found no operation stack on the clipboard.")
        return
    _replace_stack(stages, "Paste stack")
    _set_status("Pasted %s over the stack." % _operation_count(stages.size()))


# --- The right-click menu over the stack --------------------------------

## What the menu's two choices are worth as ids.
const MENU_COPY := 0
const MENU_PASTE := 1


## Opens the menu over the stack. [param index] is the entry under the pointer, or -1 for
## the empty space; [param at] is where a paste would land.
##
## [b]Paste is only offered for a clipboard holding exactly one operation.[/b] The whole
## stack tools already handle a whole stack, and a menu that pasted six operations into
## the middle of a list because the pointer happened to be there would be a surprise
## rather than a shortcut.
func _on_stack_menu(index: int, at: int) -> void:
    _stack_menu_index = index
    _stack_menu_at = at

    _stack_menu.clear()
    if index >= 0:
        _stack_menu.add_item("Copy", MENU_COPY)
    if _stages_from_text(DisplayServer.clipboard_get()).size() == 1:
        # Named for where it would land, since by the time the menu is up the pointer has
        # moved off the spot that decided it.
        var label := "Paste"
        if index >= 0:
            label = "Paste Above" if at == index else "Paste Below"
        _stack_menu.add_item(label, MENU_PASTE)
    if _stack_menu.item_count == 0:
        return

    _stack_menu.reset_size()
    _stack_menu.position = DisplayServer.mouse_get_position()
    _stack_menu.popup()


func _on_stack_menu_chosen(id: int) -> void:
    match id:
        MENU_COPY:
            _copy_one(_stack_menu_index)
        MENU_PASTE:
            _paste_one(_stack_menu_at)


## Puts one operation on the clipboard, in the same format the whole-stack Copy uses.
##
## A stack of one rather than a shape of its own, so anything that reads a saved stack
## reads this too — including Paste, which cannot tell where it came from and does not
## need to.
func _copy_one(index: int) -> void:
    var stages: Array = _stack_view.stages()
    if index < 0 or index >= stages.size():
        return
    var stage: IWStackOperation = stages[index]
    DisplayServer.clipboard_set(SettingsIO.stack_to_text([{
        "id": stage.get_operation_id(),
        "enabled": stage.enabled,
        "folded": stage.folded,
        "settings": stage.get_settings(),
    }]))
    _set_status("Copied %s." % stage.get_operation_name())


## Puts the clipboard's one operation into the stack at [param at].
func _paste_one(at: int) -> void:
    var stages := _stages_from_text(DisplayServer.clipboard_get())
    if stages.size() != 1:
        _set_status("The clipboard no longer holds a single operation.")
        return
    var stage := stages[0]
    _pending_label = "Paste %s" % stage.get_operation_name()
    # Announces, so the store, the history and the rerun all follow from it.
    _stack_view.insert_stage(stage, at)
    _set_status("Pasted %s." % stage.get_operation_name())


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


## Puts the stack in the chosen file in place of this one.
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
    _replace_stack(stages, "Load %s" % path.get_file())
    _set_status("Loaded %s from %s." % [
        _operation_count(stages.size()), path.get_file(),
    ])


## Puts [param stages] in place of whatever the stack holds now.
##
## [b]Both Paste and Load replace.[/b] Either one is a whole stack arriving, saved or
## copied as a piece, and mixing it into whatever was already there would give a stack
## nobody chose — the operations in the wrong order and the wrong number of them. Nothing
## is lost that cannot be got back: this goes into History like any other edit, so it
## rewinds. Reset is the one that does not, and it asks first for exactly that reason.
##
## [param label] is what History calls it. Left to the diff, a wholesale replacement gets
## described by whichever way the counts happened to work out, which is never what
## happened.
func _replace_stack(stages: Array[IWStackOperation], label: String) -> void:
    _pending_label = label
    _refreshing = true
    _stack_view.set_stages(stages)
    _refreshing = false
    # set_stages does not announce, because swapping images uses it too. Everything that
    # has to follow a stack changing is in here.
    _on_stack_changed()


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
    if _mode == Mode.PACKING:
        return _packing
    # The suffix and the output name come off this, and both are Upscale's own — "_x4"
    # rather than whatever the stack under it would have called its result. The stack still
    # runs; see [method _processed_image].
    if _mode == Mode.UPSCALE:
        return _upscale
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
        elif control is BrushList:
            (control as BrushList).finish_stroke()
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
                "folded": false,
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
            stage.folded = bool(entry.get("folded", false))
            records.append({
                "id": entry["id"],
                "enabled": stage.enabled,
                "folded": stage.folded,
                "settings": settings,
                "operation": stage,
            })

    _stacks_by_path[path] = records
    return records


## Operation id to script, for the sidecar codec and the stack loader.
func _operation_registry() -> Dictionary:
    var registry := {}
    for script_path: String in operation_scripts():
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
    if not _is_image_mode(_mode):
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
## Empties the stack and stops anything being added to it.
##
## With no image open there is nothing for an operation to act on, and a stack sitting
## there belongs to an image that is no longer in the list. Called alongside
## [method _blank_preview], since the two say the same thing about the same moment.
func _clear_stack() -> void:
    _refreshing = true
    _stack_view.set_stages([] as Array[IWStackOperation])
    _stack_view.set_can_add(false)
    _refreshing = false
    _update_overlays()


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
            _preview.stroke_pick = false
            if source is PolygonList:
                (source as PolygonList).finish_polygon()
                _update_overlays()
            elif source is BrushList:
                (source as BrushList).finish_stroke()
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
        elif control is BrushList:
            (control as BrushList).finish_stroke()
        control.set_pick_active(false)

    _pick_target = source
    _overlay_owner = source
    _preview.pick_mode = true
    # Three of them want a rectangle — one takes the pixels inside it, one the colours,
    # one the area to recolour. A polygon is built corner by corner and wants neither.
    _preview.region_pick = source is IslandPicker or source is ColorList \
            or source is HSVList or source is ExcludeTilesList
    # And the brush wants the whole drag rather than either end of it.
    _preview.stroke_pick = source is BrushList
    if source is BrushList:
        _set_status("Drag over the preview to paint a stroke. Escape or right-click stops.")
    elif source is ColorList:
        _set_status("Drag a region in the preview to take every color in it, or click one pixel.")
    elif source is PolygonList:
        _set_status("Click to place corners. Right-click or Escape closes the region.")
    elif source is HSVList:
        _set_status("Drag a rectangle in the preview to add it to the list.")
    elif source is ExcludeTilesList:
        _set_status("Click a tile to pick it, or drag over several. Clicking a picked one lets it go.")
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
    elif _pick_target is HSVList:
        _pick_hsv_region(region)
    elif _pick_target is ExcludeTilesList:
        _pick_tiles(region)


## Takes or lets go of every tile the swept region touches.
##
## Toggling rather than adding, because a tile the operation has removed is not in the
## picture any more and clicking its outline again is the only way to get it back.
func _pick_tiles(region: Rect2i) -> void:
    var changed := (_pick_target as ExcludeTilesList).toggle_tiles(region)
    if changed <= 0:
        return
    _set_status("%d tile%s changed." % [changed, "" if changed == 1 else "s"])


func _pick_hsv_region(region: Rect2i) -> void:
    var picked := (_pick_target as HSVList).add_region(region)
    if picked <= 0:
        return
    _set_status("Picked (%d, %d)–(%d, %d). Use the sliders to adjust it." % [
        region.position.x,
        region.position.y,
        region.end.x - 1,
        region.end.y - 1,
    ])


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


## One pixel a stroke drag has reached.
##
## [b]The stack is not re-run here.[/b] A drag reports many times a second and a run takes
## as long as the whole stack, so what the preview shows in the meantime is painted
## directly onto the pixels already on screen — over the patch this segment can reach and
## no further. The real run happens once, when the button comes up, and replaces all of it.
func _on_stroke_point(pixel: Vector2i, starting: bool) -> void:
    var painting := _painting_list()
    if painting == null:
        return
    if starting:
        painting.begin_stroke(pixel)
        _begin_live_paint(painting, pixel)
    else:
        painting.extend_stroke(pixel)
        _extend_live_paint(pixel)


## The drag ended. This is the one that re-runs, through the list's own changed signal.
##
## What was painted live stays on screen as the image until that run lands. Clearing it
## here instead would drop the preview back to the picture from before the stroke and then
## snap forward again a moment later, which reads as the stroke having failed.
func _on_stroke_finished() -> void:
    # The live paint is committed before anything else and without asking who owns the
    # tool, because this also fires when the tool is taken away mid-drag — and a patch left
    # on screen with nothing behind it able to clear it would outlive the stroke it
    # belongs to.
    var painting := _painting_list()
    if _paint_image != null:
        _result_image = _paint_image
        _preview.clear_live_patch()
        _preview.set_image(_result_image)
    _end_live_paint()
    if painting == null:
        return
    painting.finish_stroke()
    _update_overlays()


## Takes a working copy of what is on screen and starts painting into it.
##
## The copy is per drag rather than per motion event: one duplicate at the start, and after
## that nothing but the patches. Falls back to the source when no run has landed yet, which
## is what an image looks like before its first preview.
func _begin_live_paint(painting: BrushList, at: Vector2i) -> void:
    _end_live_paint()
    var shown := _result_image if _result_image != null else _source_image
    if shown == null or shown.is_empty():
        return

    _paint_base = shown.duplicate()
    if _paint_base.get_format() != Image.FORMAT_RGBA8:
        _paint_base.convert(Image.FORMAT_RGBA8)
    # What the patches are kept in. Starts as the picture, and only the pixels the stroke
    # reaches are ever written into it.
    _paint_image = _paint_base.duplicate()

    var stroke := painting.draft_stroke()
    if stroke == null:
        _end_live_paint()
        return
    _paint_radius = stroke.radius
    _paint_sharpness = stroke.sharpness
    _paint_adding = stroke.mode == IWAlphaMode.Mode.ADD

    # One float per pixel, all zero: nothing has been hit yet.
    _paint_strength = Image.create_empty(
            _paint_base.get_width(), _paint_base.get_height(), false, Image.FORMAT_RF)

    # Only an Add stroke asks what colour is under a pixel that is showing nothing, so
    # only an Add stroke pays for the copy.
    if _paint_adding and _source_image != null and not _source_image.is_empty() \
            and _source_image.get_size() == _paint_base.get_size():
        _paint_beneath = _source_image.duplicate()
        if _paint_beneath.get_format() != Image.FORMAT_RGBA8:
            _paint_beneath.convert(Image.FORMAT_RGBA8)

    _paint_at = at
    _paint_bounds = Rect2i()
    _extend_live_paint(at)


## Lays one segment onto the working copy and shows the result.
##
## Two regions are in play and they are different sizes on purpose. The segment's own box
## is what gets painted, and is as small as the brush and the distance moved allow. The
## accumulated box is what gets uploaded, since the view replaces one rectangle of the
## image and everything painted so far has to be inside it.
func _extend_live_paint(to: Vector2i) -> void:
    if _paint_image == null:
        return
    var touched := _brush_bounds(_paint_at, to)
    if touched.size.x <= 0 or touched.size.y <= 0:
        return

    var whole := Rect2i(Vector2i.ZERO, touched.size)
    var strength := _paint_strength.get_region(touched)
    var beneath: Image = null
    if _paint_beneath != null:
        beneath = _paint_beneath.get_region(touched)
    var patch: Image = IWStageKernels.paint_patch(
            _paint_base.get_region(touched), strength, beneath, touched.position,
            _paint_at, to, _paint_radius, _paint_sharpness, _paint_adding)
    if patch == null:
        return
    # The kernel updated the strength for this region in place; putting it back is what
    # carries the stroke's history into the next segment.
    _paint_strength.blit_rect(strength, whole, touched.position)
    _paint_image.blit_rect(patch, whole, touched.position)

    _paint_at = to
    _paint_bounds = touched if _paint_bounds.size.x <= 0 else _paint_bounds.merge(touched)
    _preview.set_live_patch(_paint_image.get_region(_paint_bounds), _paint_bounds)
    # The same highlight a selected stroke gets, over the one being drawn. Taken off the
    # strength map the paint is already keeping rather than by walking the path again,
    # which would grow with every mouse event and give the same answer.
    _preview.set_brush_overlay(
            IWStageKernels.strength_overlay(
                    _paint_strength.get_region(_paint_bounds), BRUSH_OVERLAY_COLOR),
            _paint_bounds)


## The pixels a segment of the brush can reach, clamped to the image.
##
## Grown by the whole radius rather than by the reach, which is half a pixel less: a
## rectangle a pixel too generous costs one row and column, and one too tight would clip
## the paint.
func _brush_bounds(from: Vector2i, to: Vector2i) -> Rect2i:
    if _paint_base == null:
        return Rect2i()
    var low := Vector2i(mini(from.x, to.x), mini(from.y, to.y)) - Vector2i.ONE * _paint_radius
    var high := Vector2i(maxi(from.x, to.x), maxi(from.y, to.y)) + Vector2i.ONE * _paint_radius
    return Rect2i(low, high - low + Vector2i.ONE).intersection(
            Rect2i(Vector2i.ZERO, _paint_base.get_size()))


## Drops the working copies. Four images the size of the sheet is the largest thing the
## dock ever holds, so they go as soon as the drag that needed them is over.
func _end_live_paint() -> void:
    _paint_image = null
    _paint_base = null
    _paint_strength = null
    _paint_beneath = null
    _paint_bounds = Rect2i()
    _paint_at = Vector2i(-1, -1)


## Whichever brush list currently owns the preview, or null.
func _painting_list() -> BrushList:
    return _pick_target as BrushList


## Ends any stroke in flight and drops out of painting, so the Draw button does not sit
## armed over a tool that is no longer receiving anything.
func _finish_painting() -> void:
    var painting := _painting_list()
    if painting == null:
        return
    painting.finish_stroke()
    painting.set_pick_active(false)
    _pick_target = null
    _preview.pick_mode = false
    _preview.stroke_pick = false
    _update_overlays()


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


## Right-click on the preview. The two drawing tools make something of it: for the polygon
## it closes the shape, for the brush it puts the tool away.
func _on_pick_cancelled() -> void:
    if _drawing_list() != null:
        _finish_polygon()
    elif _painting_list() != null:
        _finish_painting()


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
## A control's own on-and-off flags, with every one dropped when the entry holding it is
## switched off.
##
## A mark belonging to a stage that is not running has to read as not running, whatever the
## row that owns it says about itself. Exclude Tiles needs this most, since its flag says
## which tiles were picked rather than which are switched on and so carries no room for
## the answer.
func _live_flags(flags: PackedByteArray, live: bool) -> PackedByteArray:
    if live:
        return flags
    var out := PackedByteArray()
    out.resize(flags.size())
    return out


func _update_overlays() -> void:
    var islands: Array[Rect2i] = []
    var island_flags := PackedByteArray()
    var island_flooded := PackedByteArray()
    var island_tints := PackedColorArray()
    var selected_island := -1

    var regions := []
    var region_flags := PackedByteArray()
    var region_tints := PackedColorArray()
    var selected_region := -1
    var draft_region := -1

    # The brush overlay is not merged the way the others are. It is a picture of one
    # stroke's own pixels rather than a shape, and only one is ever on screen — the stroke
    # being drawn shows as paint on the image rather than as a mark over it, and two lists
    # each lighting up a row would be two answers to a question that has one.
    var brush_stroke: BrushStroke = null

    # Pictures of what an operation held back rather than removed outright, so a tile a
    # Exclude Tiles is keeping off the sheet still reads as the thing it was.
    var ghosts := []
    var ghost_regions := []
    var ghost_alphas := PackedFloat32Array()

    if _is_image_mode(_mode):
        # Walked entry by entry rather than straight down _pick_controls, which is the
        # same order — both are built by going through the entries in turn — but this way
        # each control arrives with the operation it belongs to, and that is where the
        # colour comes from.
        # Under Selected only the operation the stack is pointed at draws anything. The
        # marks sit right on top of the edges being judged, and one operation's worth is
        # often all there is room to read.
        var only: IWStackOperation = null
        if _indicators == Indicators.SELECTED:
            only = _stack_view.selected_stage()

        for entry: Control in _stack_view.entries():
            var stage: IWStackOperation = entry.stage
            if only != null and stage != only:
                continue
            var tint := stage.get_tint() if stage != null else Color.WHITE
            var live := stage != null and stage.enabled
            for control: Control in entry.pick_controls():
                if control is IslandPicker:
                    var picker := control as IslandPicker
                    var own := picker.get_islands()
                    if picker == _overlay_owner and picker.selected_index() >= 0:
                        selected_island = islands.size() + picker.selected_index()
                    islands.append_array(own)
                    island_flags.append_array(_live_flags(picker.get_enabled_flags(), live))
                    island_flooded.append_array(picker.get_flooded_flags())
                    for _i in own.size():
                        island_tints.append(tint)
                elif control is HSVList:
                    # Drawn with the islands rather than beside them: both are rectangles
                    # naming an area, and the boxes already say what one of those looks
                    # like. Flagged as flooded so they come out dashed, since a picked
                    # rectangle is exactly what it acts on rather than a guess at it.
                    var hsv := control as HSVList
                    var own_rects := hsv.get_regions()
                    if hsv == _overlay_owner and hsv.selected_index() >= 0:
                        selected_island = islands.size() + hsv.selected_index()
                    islands.append_array(own_rects)
                    island_flags.append_array(_live_flags(hsv.get_enabled_flags(), live))
                    for _i in own_rects.size():
                        island_flooded.append(1)
                        island_tints.append(tint)
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
                    region_flags.append_array(_live_flags(list.get_enabled_flags(), live))
                    for _i in own_regions.size():
                        region_tints.append(tint)
                elif control is BrushList:
                    # Only from the list the user is working in, and never the stroke
                    # being drawn: that one is showing as paint on the image already, and
                    # a second picture of it is what the switch to live painting was made
                    # to get rid of.
                    var brush := control as BrushList
                    if brush == _overlay_owner and brush.selected_index() != brush.draft_index():
                        brush_stroke = brush.selected_stroke()

        # After every pick control, never among them. selected_island is an index into the
        # joined list, worked out from how much was in it as each control was reached, so
        # anything slipped in earlier moves the highlight onto somebody else's rectangle.
        for entry: Control in _stack_view.entries():
            var stage: IWStackOperation = entry.stage
            if stage == null or (only != null and stage != only):
                continue
            var marked := stage.marked_regions()
            if marked.is_empty():
                continue
            islands.append_array(marked)
            for _i in marked.size():
                island_flags.append(1 if stage.enabled else 0)
                island_flooded.append(1)
                island_tints.append(stage.get_tint())

        # Only from a stage that actually ran, since what it held back is only true of the
        # result the switched-on stack produced.
        for entry: Control in _stack_view.entries():
            var stage: IWStackOperation = entry.stage
            if stage == null or not stage.enabled or (only != null and stage != only):
                continue
            if not (stage is ExcludeTiles):
                continue
            var settings: ExcludeTilesSettings = stage.get_settings()
            if settings == null or settings.hidden_image == null:
                continue
            ghosts.append(settings.hidden_image)
            ghost_regions.append(settings.hidden_rect)
            # Only Include Selected offers the slider, so only it gets to answer this.
            ghost_alphas.append(PreviewView.GHOST_ALPHA if settings.excluding_selected
                    else settings.hidden_opacity)

    _preview.set_markers(islands, selected_island, island_flags, island_flooded, island_tints)
    _preview.set_polygons(regions, selected_region, draft_region, region_flags, region_tints)
    _preview.set_ghosts(ghosts, ghost_regions, ghost_alphas)
    _push_brush_overlay(brush_stroke)


## Renders one stroke's own pixels and hands them to the preview, or clears the overlay.
##
## [b]The stroke rather than a line through it.[/b] A path drawn at the brush's width was
## how this started, and it marked where the stroke went rather than what it did — on a
## soft brush or a Subtract over something already faint, those are different pictures.
## Rendering the stroke through the same accumulation the paint uses lights up exactly the
## pixels it is responsible for, as strongly as it is responsible for them.
##
## Bounded by the stroke's own box grown by its brush, so a dab on a large sheet costs a
## picture the size of the dab. Rebuilt when the selection changes rather than per frame.
func _push_brush_overlay(stroke: BrushStroke) -> void:
    var shown := _result_image if _result_image != null else _source_image
    if stroke == null or not stroke.is_drawable() or shown == null or shown.is_empty():
        _preview.set_brush_overlay(null, Rect2i())
        return

    var radius: int = clampi(stroke.radius, BrushStroke.MIN_RADIUS, BrushStroke.MAX_RADIUS)
    var region := stroke.bounds().grow(radius).intersection(
            Rect2i(Vector2i.ZERO, shown.get_size()))
    if region.size.x <= 0 or region.size.y <= 0:
        _preview.set_brush_overlay(null, Rect2i())
        return

    var points := PackedInt32Array()
    for point: Vector2i in stroke.points:
        points.append(point.x)
        points.append(point.y)
    var overlay: Image = IWStageKernels.stroke_overlay(points, radius, stroke.sharpness,
            region.position, region.size, BRUSH_OVERLAY_COLOR)
    _preview.set_brush_overlay(overlay, region)


func _on_setting_changed() -> void:
    if _refreshing:
        return
    # A setting can be the switch that hides another one, and nothing but this would
    # notice it had been thrown.
    if _mode == Mode.RENAME:
        SettingsBuilder.refresh_visibility(_rename, _rename_box)
    elif _mode == Mode.PACKING:
        SettingsBuilder.refresh_visibility(_packing, _packing_box)
    elif _mode == Mode.UPSCALE:
        SettingsBuilder.refresh_visibility(_upscale, _upscale_box)
    else:
        for entry: Control in _stack_view.entries():
            SettingsBuilder.refresh_visibility(entry.stage, entry.settings_box())
        # And a setting can be what makes a stage need something above it — the first
        # Subtract island picked is the case — so the notes are asked again too.
        _refresh_notes()
        _capture_history()
    _schedule_autosave()
    if _mode == Mode.PACKING:
        # The note under the dropdown is the one part of this form that is not a setting,
        # so nothing else would notice the mode had moved.
        _refresh_packing_note()
        # Only when the sheet itself would come out different. Create Lookup Table is
        # answered at save time out of a plan already made, and repacking for it would cost
        # a run of every open image's stack to arrive back at the same pixels.
        var key := _packing_sheet_signature()
        if key != _packing_sheet_key:
            _packing_sheet_key = key
            _schedule_packing()
        elif _packing_normal_signature() != _packing_normal_key:
            # Only when nothing above it already asked for a repack, since a repack works the
            # map out again anyway. This is a pass over pixels that exist, not a run of every
            # open image's stack.
            _schedule_packing_normals()
        return
    if _mode == Mode.UPSCALE:
        # A setting can be the one that changes what the form itself holds, and rebuilding
        # is the only way to follow that. Deferred because we are inside the signal of a
        # control the rebuild is about to free.
        if _upscale_form_signature() != _upscale_form_key:
            _upscale_form_key = _upscale_form_signature()
            _build_upscale.call_deferred()
        _refresh_upscale_note()
        # The one tab whose suffix follows a setting rather than naming the operation, so
        # changing the ratio has to move it. Only while the user has not typed their own;
        # _refresh_suffix is what decides that.
        _refresh_suffix()
        _schedule_upscale()
        return
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


## Refresh means "do it now" on whichever tab is up.
##
## Routed here rather than wired straight to the preview, because two of the tabs run
## something that is not one — and both of them are exactly the case Refresh exists for,
## since both stand down from running automatically once the work gets large.
func _on_refresh_pressed() -> void:
    if _mode == Mode.PACKING:
        _run_packing_now()
    elif _mode == Mode.UPSCALE:
        _run_upscale_now(true)
    else:
        _run_preview()


## Asks for a preview, starting one now or replacing the run in flight.
##
## Only ever one run at a time. A request arriving mid-run tells that run to stop and
## leaves a note to start again; the run gives up at its next checkpoint, and the handler
## that collects it starts the replacement.
func _run_preview() -> void:
    _debounce.stop()
    if _shutting_down or _source_image == null or not _is_image_mode(_mode):
        return
    if _preview_running:
        _preview_pending = true
        if _preview_worker_op != null:
            _preview_worker_op.cancelled = true
        return
    _start_preview()


## Starts a run and puts the preview into its working state.
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

    worker.progress_reporter = _on_preview_progress
    if worker is IWPipeline:
        (worker as IWPipeline).stage_progress_reporter = _on_preview_stage_progress

    # set_busy resets the bar even when it is already up, so a restart begins from
    # nothing rather than from wherever the abandoned run had got to.
    _preview.set_busy(true)
    _preview_worker_op = worker
    _preview_running = true
    _run_preview_here(worker, source)


## The run itself: on the main thread, a stage at a time.
##
## Stepped rather than run straight through, because a bar nobody can see is not a bar.
## The main thread does the painting, so while it is inside a stack of stages nothing on
## screen changes — set_busy and every report in between would land as one repaint at the
## end, on their way out. Yielding between stages gets each of them drawn.
##
## The editor is live during those yields, so a request arriving mid-run is caught by
## [member _preview_running] and cancels this one, and the answer is dropped if the dock
## left the tree while a stage was running.
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


## Takes delivery of a finished run.
func _on_preview_done(source: Image, result: Image, elapsed: int) -> void:
    # The dock is on its way out. Nothing below has anywhere to put an answer.
    if _shutting_down:
        return
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
    if _preview_pending and _source_image != null and _is_image_mode(_mode):
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
    # A run is the only thing that moves a readout describing what the run found, and no
    # setting changed, so nothing else would ask the forms to say it again.
    for entry: Control in _stack_view.entries():
        SettingsBuilder.refresh_visibility(entry.stage, entry.settings_box())


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
# --- Packing -------------------------------------------------------------

## Asks for a rebuild shortly, for a change that ought to produce one.
##
## Debounced rather than immediate, and by a good deal more than the preview is: every
## change here costs a run of every open image's stack, and a spinner being dragged reports
## a change per pixel.
func _schedule_packing() -> void:
    # The timer is null while the dock is being built, and _refresh_file_list runs during
    # that — so this is reached before there is anything to start.
    if _mode != Mode.PACKING or _shutting_down or _packing_debounce == null:
        return
    _packing_debounce.start()


## Builds the sheet, or says why it could not.
##
## [b]Queued rather than refused when one is already going.[/b] Two interleaved runs would
## fight over the preview, but dropping the second would leave the sheet describing
## settings that are no longer on screen — which is the one thing an automatic rebuild must
## not do. So the request is remembered and answered as soon as the run in flight is done.
func _run_packing_now() -> void:
    if _mode != Mode.PACKING or _shutting_down or _packing == null:
        return
    if _packing_running:
        _packing_pending = true
        return
    if _sources.is_empty():
        _forget_packed_sheet()
        _update_preview_texture()
        _set_packing_status("Nothing to pack: add some images to the list.")
        return

    _packing_running = true
    _update_controls()
    _preview.set_busy(true)
    await _run_packing()
    if _shutting_down:
        return
    _packing_running = false
    _preview.set_busy(false)
    _update_controls()

    # Something changed while that was running, so the sheet just built is already out of
    # date. Round again, through the debounce so a burst of changes still collapses.
    if _packing_pending:
        _packing_pending = false
        _schedule_packing()


## Reads every open image, cuts the objects out of each, and lays them on one sheet.
##
## [b]Stepped through the same way a preview is.[/b] The main thread does the painting, so
## running a dozen stacks straight through would freeze the dock and land every progress
## report as one repaint on the way out. Awaiting between images gets each of them drawn,
## and leaves the editor live enough to be closed halfway through.
func _run_packing() -> void:
    var sprites := []
    var read := 0
    var total := _sources.size()

    for i in total:
        if _shutting_down:
            return
        var path := _sources[i]
        _set_packing_status("Reading %s  (%d of %d)" % [path.get_file(), i + 1, total])
        _preview.set_progress(float(i) / float(total))

        var image := _load_image(path)
        if image == null:
            continue
        var pipeline := _pipeline_for(path)
        var result: Image = await pipeline.process_image_stepped(image, get_tree().process_frame)
        if _shutting_down:
            return
        if result == null:
            result = image
        read += 1
        sprites.append_array(_sprites_in(result))

    if sprites.is_empty():
        _forget_packed_sheet()
        _update_preview_texture()
        _set_packing_status("Nothing to pack: no objects were found in %d image%s."
                % [read, "" if read == 1 else "s"])
        return

    var sizes := []
    for sprite: Image in sprites:
        sizes.append(sprite.get_size())

    var plan: Dictionary = _packing.plan(sizes)
    var positions: Array = plan["positions"]
    var placed: int = plan["placed"]
    # The size the plan was actually made for, which is not the one in the settings once
    # Expand to Fit has grown it.
    var packed_width: int = plan["width"]
    var packed_height: int = plan["height"]
    if placed < sprites.size():
        _warn_packing_overflowed(placed, sprites.size(), packed_width, packed_height)
        return

    var sheet := Image.create_empty(
            packed_width, packed_height, false, Image.FORMAT_RGBA8)
    sheet.fill(Color(0, 0, 0, 0))
    # Filled alongside the painting so the two cannot disagree: a sprite that went down is a
    # rectangle in the table, and one that did not is a rectangle of no area rather than a
    # gap that would shift every sprite after it onto the wrong number.
    var rects: Array = []
    for i in sprites.size():
        var at: Vector2i = positions[i]
        if at.x < 0:
            rects.append(Rect2i())
            continue
        sheet.blit_rect(sprites[i], Rect2i(Vector2i.ZERO, sizes[i]), at)
        rects.append(Rect2i(at, sizes[i]))

    _packing_image = sheet
    _packing_rects = rects
    # A new sheet is new sprites in new places, so whatever map was held describes nothing
    # that is on screen any more. This updates the preview itself.
    _rebuild_packing_normals()
    _preview.fit_to_view()
    var settings := _packing.get_settings()
    var grown := ""
    if packed_width != settings.output_width or packed_height != settings.output_height:
        grown = "  (expanded from %d x %d)" % [settings.output_width, settings.output_height]
    _set_packing_status("Packed %d sprite%s from %d image%s onto %d x %d.%s"
            % [sprites.size(), "" if sprites.size() == 1 else "s",
                    read, "" if read == 1 else "s",
                    packed_width, packed_height, grown])


## Every object in one processed image, each cut out on its own.
func _sprites_in(image: Image) -> Array:
    var ctx := IWPipelineContext.from_image(image)
    var out := []
    for sprite: Image in IWStageKernels.cut_islands(ctx):
        out.append(sprite)
    return out


## A fresh pipeline carrying [param path]'s stack.
##
## The highlighted image is taken off the stack view rather than the store, since that is
## where an edit made a moment ago still is. Every other image is taken from the store,
## which is what it was last saved or loaded as.
func _pipeline_for(path: String) -> IWPipeline:
    if path == _current_path():
        return _snapshot_pipeline(_stack_view.stages())
    var stages := []
    for record: Dictionary in _stack_for(path):
        var stage: Variant = record.get("operation")
        if stage is IWStackOperation:
            stages.append(stage)
    return _snapshot_pipeline(stages)


## Says the sheet was too small, and leaves what was on screen alone.
##
## [b]Nothing is shown for a run that did not finish.[/b] A half-packed sheet is a picture
## of an answer that does not exist, and the one thing it would be read as — this is what
## you asked for — is the one thing it is not.
##
## [param width] and [param height] are the sheet actually tried, which is the grown one
## when Expand to Fit has been at it — so the number in the message is the number that was
## not enough rather than the one still showing in the form.
func _warn_packing_overflowed(placed: int, total: int, width: int, height: int) -> void:
    var settings := _packing.get_settings()
    var expanded: bool = width != settings.output_width or height != settings.output_height
    var title := ""
    var message := ""
    if expanded:
        title = "Too Big to Pack"
        message = "Grew the sheet to %d x %d, the largest a texture may be, and %d of %d sprites still did not fit.\n\nPack fewer images at once, or use Tight, which fits the most." % [width, height, placed, total]
    else:
        title = "Not Enough Room"
        message = "Ran out of room on the %d x %d sheet.\n\n%d of %d sprites fitted. Make the sheet larger, or try a different packing mode — Tight fits the most." % [width, height, placed, total]

    _set_packing_status("Ran out of room: %d of %d sprites fitted on %d x %d."
            % [placed, total, width, height])
    if _packing_dialog == null:
        return
    _packing_dialog.title = title
    _packing_dialog.dialog_text = message
    _packing_dialog.popup_centered()


func _set_packing_status(text: String) -> void:
    if _packing_status != null:
        _packing_status.text = text


## Drops the sheet and the layout together, since one without the other is a trap.
##
## The normal map goes with them: it describes those sprites at those positions, and nothing
## about it survives the sheet it was made from.
func _forget_packed_sheet() -> void:
    _packing_image = null
    _packing_rects = []
    _packing_normal_image = null
    _packing_normal_key = ""


## Asks for the normal map shortly, for a change that only the map reads.
func _schedule_packing_normals() -> void:
    # Null while the dock is being built, exactly as the packing timer is.
    if _mode != Mode.PACKING or _shutting_down or _packing_normal_debounce == null:
        return
    _packing_normal_debounce.start()


## Works the normal map out for the sheet on screen, or drops it when normals are off.
func _rebuild_packing_normals() -> void:
    _packing_normal_key = _packing_normal_signature()
    if _packing == null or _packing_image == null:
        _packing_normal_image = null
    else:
        _packing_normal_image = _packing.build_normal_map(_packing_image, _packing_rects)
    _update_normal_toggle()
    _update_preview_texture()


## Shows the toggle only when there is a map to show, and drops the preview back to the sheet
## when there is not — so it cannot be left looking at a map that is no longer made.
func _update_normal_toggle() -> void:
    if _packing_normal_toggle == null:
        return
    var offered := _packing_normal_image != null
    _packing_normal_toggle.visible = offered
    if not offered:
        _showing_normals = false
    # Written rather than read, so a rebuilt dock comes back showing what it was showing.
    _packing_normal_toggle.set_pressed_no_signal(_showing_normals)


func _on_show_normals_toggled(pressed: bool) -> void:
    _showing_normals = pressed
    _update_preview_texture()


## The settings that decide what the normal map looks like, as one string.
##
## Deliberately no overlap with [method _packing_sheet_signature]: not one of these changes a
## pixel of the sheet, and repacking for any of them would cost a run of every open image's
## stack to arrive back at exactly the same sprites.
func _packing_normal_signature() -> String:
    if _packing == null:
        return ""
    var settings := _packing.get_settings()
    return "%d/%.3f/%d/%d/%.3f/%.3f/%d/%.3f/%s/%s" % [settings.normals,
            settings.normal_strength, settings.normal_roll_off, settings.normal_curve,
            settings.normal_color_tolerance, settings.normal_coarse,
            settings.normal_coarse_size, settings.normal_fine, settings.normal_green_down,
            settings.normal_model_dir]


## The settings that decide what the sheet looks like, as one string.
##
## Create Lookup Table is deliberately not in it — that is the whole point of the thing. See
## [member _packing_sheet_key].
func _packing_sheet_signature() -> String:
    if _packing == null:
        return ""
    var settings := _packing.get_settings()
    return "%d/%d/%d/%s" % [settings.mode, settings.output_width, settings.output_height,
            settings.expand_to_fit]


# --- Upscaling -----------------------------------------------------------

## Asks for a run shortly, for a change that ought to produce one.
##
## Debounced like Packing's and by as much, since a dropdown is a dropdown but the ratio
## spinner is not the only thing on this form and every change costs a whole stack plus a
## pass of a neural network.
## Why the Upscale tab cannot do anything, or empty when it can.
##
## Two unrelated reasons, answered together because every caller wants both: the native
## class may not be in this build at all, and the settings dialled in may be a combination
## that has no model behind it.
func _upscale_blocked() -> String:
    var missing: String = Upscale.unavailable_note()
    if not missing.is_empty():
        return missing
    return _upscale.combination_note() if _upscale != null else ""


func _schedule_upscale() -> void:
    # Null while the dock is being built, and _refresh_file_list runs during that.
    if _mode != Mode.UPSCALE or _shutting_down or _upscale_debounce == null:
        return
    _upscale_debounce.start()


## Whether a run is small enough to start on its own.
##
## Judged on the size coming out rather than the size going in, which is the whole
## difference here: a 512-square sprite is nothing, and the same sprite at 32x is a quarter
## of a billion pixels and several minutes.
func _upscale_auto_allowed() -> bool:
    if _source_image == null or _upscale == null:
        return false
    var out: Vector2i = _upscale.output_size(_source_image.get_size())
    return out.x * out.y <= UPSCALE_AUTO_PIXEL_LIMIT


## Runs the highlighted image, or says why it could not.
##
## [param forced] is Refresh, which is what asks for a run the size test above declined.
## Queued rather than refused when one is already going, for the reason Packing is: a
## dropped request would leave the picture describing settings no longer on screen.
func _run_upscale_now(forced := false) -> void:
    if _mode != Mode.UPSCALE or _shutting_down or _upscale == null:
        return

    var blocked := _upscale_blocked()
    if not blocked.is_empty():
        _upscale_image = null
        _upscale_source = null
        _update_preview_texture()
        _set_upscale_status(blocked)
        # The Save buttons go with it, since what they would run is what cannot run.
        _update_controls()
        return
    if _upscale_running:
        _upscale_pending = true
        return
    if _source_image == null:
        _upscale_image = null
        _upscale_source = null
        _update_preview_texture()
        _set_upscale_status("Nothing to upscale: pick an image from the list.")
        return
    if not forced and not _upscale_auto_allowed():
        var out: Vector2i = _upscale.output_size(_source_image.get_size())
        _upscale_image = null
        _upscale_source = null
        _update_preview_texture()
        _set_upscale_status("%d x %d is a lot to make for a preview. Press Refresh to run it."
                % [out.x, out.y])
        return

    _upscale_running = true
    _update_controls()
    _preview.set_busy(true)
    await _run_upscale()
    if _shutting_down:
        return
    _upscale_running = false
    _preview.set_busy(false)
    _update_controls()

    if _upscale_pending:
        _upscale_pending = false
        _schedule_upscale()


## The run: the highlighted image's stack, then the network.
##
## [b]The stack first, and that order is the point of the tab.[/b] A background keyed out at
## the size the file arrived at is keyed against edges the camera or the brush actually put
## there. Keyed after upscaling, it is keyed against edges the network invented — and the
## network is very good at inventing a confident edge in the wrong place.
func _run_upscale() -> void:
    var path := _current_path()
    var source := _source_image
    var signature: String = _upscale.network_signature()

    # Nothing the network cares about has moved, so what it said last time still stands and
    # only the Sharpen remap has to run again. That is a pass over the alpha against a
    # lookup table, which is why the slider can be dragged at all.
    if _upscale_raw != null and _upscale_raw_source == source and _upscale_raw_key == signature:
        _upscale_image = _upscale.sharpen_image(_upscale_raw)
        _upscale_source = source
        _update_preview_texture()
        _set_upscale_status("Sharpen %.2f, on the picture already made — the network did not run again."
                % _upscale.settings.sharpen)
        return

    _set_upscale_status("Running %s through its operations..." % path.get_file())
    _preview.set_progress(0.0)
    var pipeline := _pipeline_for(path)
    var staged: Image = await pipeline.process_image_stepped(source, get_tree().process_frame)
    if _shutting_down:
        return
    if staged == null:
        staged = source

    var out: Vector2i = _upscale.output_size(staged.get_size())
    _set_upscale_status("Upscaling to %d x %d. This does not report progress." % [out.x, out.y])
    _preview.set_progress(0.5)
    # [b]One frame, deliberately.[/b] The line above is painted by the main thread, and the
    # call below occupies the main thread for as long as the network takes — so without this
    # the message would arrive at the same moment as the answer it was there to explain.
    await get_tree().process_frame
    if _shutting_down:
        return

    var started := Time.get_ticks_msec()
    # The network's answer on its own, so it can be kept and re-sharpened. Sharpen is
    # applied below rather than by process_image, which does both in one call for everything
    # that is not this preview.
    var result: Image = _upscale.upscale_only(staged)
    if _shutting_down:
        return

    var failure: String = _upscale.last_error
    if not failure.is_empty():
        _upscale_raw = null
        _upscale_image = null
        _upscale_source = null
        _update_preview_texture()
        _set_upscale_status(failure)
        _set_status(failure)
        return

    _upscale_raw = result
    _upscale_raw_source = source
    _upscale_raw_key = signature
    result = _upscale.sharpen_image(result)
    _upscale_image = result
    _upscale_source = source
    _update_preview_texture()
    _preview.fit_to_view()
    var elapsed := Time.get_ticks_msec() - started
    _set_upscale_status("%s at %dx: %d x %d in %d ms." % [
        path.get_file(), _upscale.scale_ratio(), result.get_width(), result.get_height(), elapsed,
    ])
    _set_status("Upscaled %s in %d ms." % [path.get_file(), elapsed])


func _set_upscale_status(text: String) -> void:
    if _upscale_status != null:
        _upscale_status.text = text


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
    # Packing shows the sheet it made rather than the highlighted file, which is the whole
    # point of it — and no original underneath, since there is no one source for the fade
    # to bring back. Before the null test below, because a packing is worth looking at
    # whether or not a file happens to be highlighted.
    if _mode == Mode.PACKING:
        # The normal map when it is being looked at, and the sheet underneath it rather than
        # nothing — the two are the same size and line up pixel for pixel, so the fade slider
        # answers the one question a normal map raises: is that rounding following the art.
        var showing_map := _showing_normals and _packing_normal_image != null
        _preview.set_image(_packing_normal_image if showing_map else _packing_image)
        _preview.set_original(_packing_image if showing_map else null)
        # The rectangles the sheet was painted from, so the preview can say where one
        # sprite ends and the next begins — which is the one thing a packed sheet cannot be
        # read off itself.
        _preview.set_tile_bounds(_packing_rects if _packing_image != null else [])
        return
    # Every other tab clears them, since a sheet's tiles mean nothing on another image and
    # the preview is the same control throughout.
    _preview.set_tile_bounds([])
    # Upscale shows what it made, and no original underneath: the result is a different
    # size from the source, so there is nothing for the fade slider to lay one over the
    # other — it would be comparing two pictures that do not line up.
    if _mode == Mode.UPSCALE:
        _preview.set_image(_upscale_image if _upscale_source == _source_image else null)
        _preview.set_original(null)
        return
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
    # Packing has one thing to save and it is not a file from the list, so Save Current
    # writes the sheet and Save All has nothing to mean. Disabled rather than hidden: a
    # button that comes and goes with a tab reads as a bug in the layout, where a dead one
    # reads as "not from here".
    if _mode == Mode.PACKING:
        _process_selected_button.disabled = _packing_image == null
        _process_all_button.disabled = true
        return
    # Upscale is the other way round: every image comes out as its own file, so both
    # buttons mean what they mean everywhere else. They only stand down when nothing they
    # could do would work — the class missing from the build, or a ratio and a model that
    # cannot go together. Neither is something clicking would fix.
    if _mode == Mode.UPSCALE and not _upscale_blocked().is_empty():
        _process_selected_button.disabled = true
        _process_all_button.disabled = true
        return
    _process_selected_button.disabled = _source_image == null
    _process_all_button.disabled = not has_any



# --- Writing results ----------------------------------------------------

## Processing one image asks where to put it, so the Save As dialog carries the
## whole decision — no destination is remembered between runs.
func _on_process_selected() -> void:
    if _mode == Mode.PACKING:
        _save_packed_sheet()
        return
    var index := _selected_index()
    if index < 0:
        return
    var path := _sources[index]
    _save_source = path
    _save_dialog.current_dir = path.get_base_dir()
    _save_dialog.current_file = _output_name_for(path)
    _save_dialog.popup_centered_ratio(0.6)


func _on_save_file_chosen(destination: String) -> void:
    # The sheet is not one of the sources and has nothing to be processed from, so it
    # takes the short way out rather than through the job list below.
    if _saving_sheet:
        _saving_sheet = false
        _write_packed_sheet(destination)
        return
    var source := _save_source
    _save_source = ""
    if source.is_empty():
        return
    # FILE_MODE_SAVE_FILE has already asked about replacing an existing file, so
    # this goes straight to writing.
    _pending_outputs = {source: destination}
    _write_pending_outputs()


## Asks where to put the packed sheet.
##
## [b]Named off the first image rather than off the highlighted one.[/b] The sheet is made
## from the whole list and belongs to none of them, but a name has to come from somewhere —
## and the first is the one that does not change when you click down the list looking at
## what went into it.
func _save_packed_sheet() -> void:
    if _packing_image == null or _sources.is_empty():
        _set_status("Nothing packed yet.")
        return
    _saving_sheet = true
    _save_source = ""
    var first := _sources[0]
    _save_dialog.current_dir = first.get_base_dir()
    _save_dialog.current_file = "%s%s.png" % [first.get_file().get_basename(),
            _packing.get_output_suffix() if _packing != null else "_packed"]
    _save_dialog.popup_centered_ratio(0.6)


## Writes the sheet, and says so.
##
## PNG regardless of what the name says, which is what the dialog offers and what every
## other write here does — and the only one of the formats on offer that keeps the
## transparency between the sprites.
func _write_packed_sheet(destination: String) -> void:
    if _packing_image == null:
        return
    var directory := destination.get_base_dir()
    if not DirAccess.dir_exists_absolute(directory):
        if DirAccess.make_dir_recursive_absolute(directory) != OK:
            _set_status("Could not make %s." % directory)
            return
    if _packing_image.save_png(destination) != OK:
        _set_status("Could not write %s." % destination.get_file())
        return

    var written := PackedStringArray([destination.get_file()])
    var settings: PackingSettings = _packing.get_settings() if _packing != null else null

    if settings != null and settings.create_lookup_table:
        var table := _write_lookup_table(destination)
        if table.is_empty():
            _report_sheet_written(written, "the lookup table")
            return
        written.append(table)

    if settings != null and _packing.sanitise_normals(settings.normals) \
            != IWPacking.NormalMode.DISABLED:
        var map := _write_normal_map(destination)
        if map.is_empty():
            _report_sheet_written(written, "the normal map")
            return
        written.append(map)

    _report_sheet_written(written, "")


## Says what was written, and which of the extra files was not.
##
## The sheet is on disk and is the thing that was asked for, so a failure below it reports
## the half that failed rather than pretending the whole write did. [param failed] empty
## means everything asked for went out.
func _report_sheet_written(written: PackedStringArray, failed: String) -> void:
    var names := ", ".join(written.slice(0, written.size() - 1))
    if not names.is_empty():
        names = "%s and %s" % [names, written[written.size() - 1]]
    else:
        names = written[0]
    var line := "Saved %s." % names if failed.is_empty() \
            else "Saved %s, but could not write %s." % [names, failed]
    _set_status(line)
    _set_packing_status(line)


## Writes the lookup table beside the sheet, and returns what it was called — or an empty
## string if it could not be written.
##
## [b]A resource rather than an image.[/b] The rectangles are floats and have to stay
## floats, and a [code].res[/code] is the only way out of here that keeps them: it is read
## back exactly as written, where anything going through the image importer would come back
## as bytes. See [method IWPacking.build_lookup_texture].
func _write_lookup_table(sheet_path: String) -> String:
    if _packing_rects.is_empty():
        return ""
    var destination := IWPacking.lookup_path_for(sheet_path)
    var table := IWPacking.build_lookup_texture(_packing_rects)
    if ResourceSaver.save(table, destination) != OK:
        return ""
    return destination.get_file()


## Writes the normal map beside the sheet, and returns what it was called — or an empty
## string if it could not be written.
##
## [b]A PNG, where the lookup table is a resource.[/b] That one holds coordinates that have
## to survive as floats; this is a picture, and every tool that reads a normal map reads one.
##
## Worked out here if the preview never did, so saving cannot depend on which way the preview
## toggle happened to be left.
func _write_normal_map(sheet_path: String) -> String:
    if _packing == null or _packing_image == null:
        return ""
    if _packing_normal_image == null:
        _rebuild_packing_normals()
    if _packing_normal_image == null:
        return ""
    var destination := IWPacking.normal_path_for(sheet_path)
    if _packing_normal_image.save_png(destination) != OK:
        return ""
    return destination.get_file()


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
        if not carries_sidecars:
            continue
        # Both names, since an image whose settings were never opened may still have an
        # unconverted one beside it — and whichever is there is the one that travels.
        var sources := SettingsIO.sidecar_paths(path)
        var destinations := SettingsIO.sidecar_paths(destination)
        for i in sources.size():
            if not FileAccess.file_exists(sources[i]):
                continue
            # Only ours is listed: one belonging to something else is refused rather
            # than replaced, so naming it here would promise a write that never comes.
            if SettingsIO.is_sidecar(destinations[i]):
                existing.append(destinations[i].get_file())

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
## [code]flower.jpg[/code] in one folder share [code]flower.iwc[/code]. Renaming only one
## of them must not carry that file away from the other, which would strip settings off an
## image this run never touched.
func _sidecars_held_outside(jobs: Dictionary) -> Dictionary:
    var held := {}
    for path in _sources:
        var source := String(path)
        if jobs.has(source):
            continue
        for sidecar in SettingsIO.sidecar_paths(source):
            held[sidecar] = true
    return held


## Copies a source's settings counterpart alongside the copy of the image, and queues
## the original for the same removal check the image gets.
##
## The sidecar describes the image, so a rename that left it behind would strand
## every per-image setting the moment the dock was reopened — and, with Remove Old
## Files ticked, orphan it beside a file now in the trash. Whatever sits at the
## sidecar path travels, ours or not — the name is distinctive enough now that it
## almost certainly is ours, and a stranger's file named for this image belongs with
## it just as much.
##
## [b]Both names are tried.[/b] An image whose settings were never opened in this session
## has never been through the conversion, so what is beside it may still be the old
## [code]_wrangler.json[/code] — and a rename that carried only the name it has not got yet
## would leave the settings behind. Renaming is not the place to convert: it is a file
## operation, and the file it would have to rewrite belongs to an image nobody has looked
## at. Opening that image afterwards converts it where it now lives.
##
## Returns the empty String when the sidecars were carried or there were none, and
## the name of the first file left behind otherwise. Never fails the image: by the time
## this runs the image is already written, and reporting a rename as failed
## because of its sidecar would be a lie about what is on disk.
func _carry_sidecar(source_path: String, destination: String, held: Dictionary) -> String:
    var sources := SettingsIO.sidecar_paths(source_path)
    var destinations := SettingsIO.sidecar_paths(destination)
    var stranded := ""
    for i in sources.size():
        var left := _carry_one_sidecar(sources[i], destinations[i], held)
        if stranded.is_empty():
            stranded = left
    return stranded


## One sidecar carried from [param source_sidecar] to [param destination_sidecar].
##
## Split out of [method _carry_sidecar] only so that the two names it has to try are a loop
## rather than the same twenty lines twice.
func _carry_one_sidecar(source_sidecar: String, destination_sidecar: String, held: Dictionary) -> String:
    if not FileAccess.file_exists(source_sidecar):
        return ""

    # Both sidecars are named from their image's basename, so a rename that only
    # changed the extension's case leaves them the same file. Copying it onto
    # itself would truncate it.
    if _is_same_file(source_sidecar, destination_sidecar):
        return ""

    # The one case where refusing beats writing: a file already at the new name
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


## The finished pixels for one source: its own stack, and then whatever the tab adds on top.
##
## [b]A fresh pipeline per job, built from that image's own saved stack.[/b] Nothing the
## dock is showing is touched, which is what lets the form go on being edited during a run
## and what stops one image's settings leaking into the next.
##
## Returns null when the upscaler could not run, with the reason left in
## [member _upscale_failure] — one line for the whole run rather than one per file, since a
## missing model or a GPU out of memory fails every image for the same reason and twenty
## copies of it is not twenty pieces of information.
func _processed_image(source_path: String, image: Image) -> Image:
    var stages := []
    for record: Dictionary in _stack_for(source_path):
        var stage: IWStackOperation = record["operation"]
        stage.set_settings(record["settings"])
        stage.enabled = bool(record["enabled"])
        stages.append(stage)
    var result := _snapshot_pipeline(stages).process_image(image)

    if _mode != Mode.UPSCALE or _upscale == null:
        return result

    # The stack's result, not the file's pixels. See [method _run_upscale] for why that
    # order is the whole point of the tab.
    var upscaled: Image = _upscale.process_image(result)
    var failure: String = _upscale.last_error
    if not failure.is_empty():
        _upscale_failure = failure
        return null
    return upscaled


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
    # extension. Asked of the operation rather than of the mode, which is the same
    # question one step nearer the answer — and the only form of it that stayed right
    # when Upscale arrived on the far side of [method _is_image_mode] while still
    # rewriting every pixel it touches.
    var active := _active_operation()
    var rewrites_pixels := active != null and active.transforms_pixels()
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
        var result := _processed_image(source_path, image)
        if result == null:
            failures.append(source_path.get_file())
            continue
        if result.save_png(destination) != OK:
            failures.append(source_path.get_file())
            continue
        written += 1

    var report := "Wrote %d file(s)." % written
    if not failures.is_empty():
        report = "Wrote %d file(s), %d failed: %s" % [written, failures.size(), ", ".join(failures)]
        push_error("Image Wrangler: failed to process %s" % ", ".join(failures))
    if not _upscale_failure.is_empty():
        report += " %s" % _upscale_failure
        _upscale_failure = ""
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
