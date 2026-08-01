@tool
extends RefCounted

## Reads and writes the sidecar that carries one image's settings.
##
## The sidecar sits beside the image, named for it: [code]flower.png[/code] →
## [code]flower.iwc[/code]. See [constant SIDECAR_SUFFIX]. It holds an ordered list of
## stages, each keyed by [method IWOperation.get_operation_id], so an operation can start
## saving its own settings without breaking the format:
## [codeblock]
## {
##     "format": "image_wrangler",
##     "version": 2,
##     "stack": [
##         { "id": "remove_background", "enabled": true, "settings": { ... } },
##     ]
## }
## [/codeblock]
##
## [b]That envelope is written as Godot's own binary variant format, not as JSON.[/b] It is
## smaller, it is read and written without a parser, and it keeps the types it was given —
## where JSON has one number type, so every int came back a float and had to be talked back
## into shape on the way in. See [method _read_envelope]. The file that used to hold it,
## [code]flower_wrangler.json[/code], is still read when one is found, and converting it is
## the first thing that happens; see [method migrate_legacy_sidecar].
##
## Encoding is generic, driven by reflection over the settings Resource rather
## than hand-written per class. The addon's whole premise is that adding an
## operation needs no plumbing beyond the operation itself, and persistence has
## to follow the same rule as the UI does or that promise is only half true. It
## also means a value no schema entry ever names — [member
## RemoveColorSample.color_tolerance] is one, sitting two levels below the property
## the schema declares — persists anyway, and that a fourteenth tunable cannot be
## added and silently not saved.

const FORMAT := "image_wrangler"

## Bumped to 2 when the single operation became a stack. A version 1 file holds one
## block per operation keyed by id, which cannot express an order or the same
## operation twice; a version 2 file holds an ordered list. See [method load_stack].
const VERSION := 2

## Ids of the stages a version 1 [code]remove_background[/code] block splits into,
## in the order that reproduces what it used to do.
##
## Islands above the crevice, because in version 1 island seeds joined the same
## flood the crevice rule then extended. Polygons above the keying, because a cut
## has to be declared before the alpha is estimated so it can steer where the
## colour bleed takes its replacements from.
const _V1_ORDER := [
    &"polygon_edit",
    &"remove_background",
    &"island_picker",
    &"remove_crevice",
    &"refine_edges",
    &"edge_cleanup",
]

## Operation ids that existed in a saved file but no longer name an operation.
##
## Dropped without a warning, unlike an id nobody recognises: these were ours, and the
## settings they carried have a home to go to. See [method _absorb_retired].
##
## Empty at the moment. [code]remove_crevice[/code] was here while the crevice rule
## lived inside the background flood, and is an operation again — a file written while
## it was retired carries its values inside the background block instead, which
## [method _crevice_from_block] takes back out.
const _RETIRED_IDS := {}

## Operation ids that changed name, mapped to what they are called now. The settings kept
## their names, so an old id is read straight into the new one.
const _RENAMED_IDS := {
    &"tile_selector": &"exclude_tiles",
}


## What a sidecar's name is the image's basename plus.
##
## [code]flower.png[/code] → [code]flower.iwc[/code], for Image Wrangler Config. An
## extension of its own is what a plain [code].json[/code] never was: beside an image,
## [code]sprite.json[/code] is one of the most contested names on disk — it is exactly what
## Aseprite calls its atlas descriptor — and this addon works in precisely those folders.
## Claiming a name nothing else wants is a better answer than being careful with a name
## everything wants, which is what [method is_sidecar] and the refusals below were left
## doing alone.
##
## They stay anyway. An extension nobody else uses makes a collision unlikely rather than
## impossible, and the cost of being wrong is somebody else's file overwritten.
const SIDECAR_SUFFIX := ".iwc"

## What sidecars were called before [constant SIDECAR_SUFFIX], and are still read from.
##
## Never written. One found beside a loaded image is converted and then removed; see
## [method migrate_legacy_sidecar].
const LEGACY_SIDECAR_SUFFIX := "_wrangler.json"

## What a binary sidecar starts with, so one can be told from any other file of that name
## before a byte of it is trusted.
##
## JSON had this for free — text that does not parse is not ours. Binary has no such tell,
## and [method FileAccess.get_var] pointed at somebody else's bytes is a worse thing than a
## parser pointed at somebody else's text.
const MAGIC := "IWCF"

## The container's version, which is not the settings format's.
##
## [constant VERSION] describes what the envelope means; this describes how it is written
## down. They move for different reasons — the stack becoming a list was the former, and a
## change of serialization would be the latter.
const CONTAINER_VERSION := 1


## Sidecar path for a source image: its path with the extension replaced by
## [constant SIDECAR_SUFFIX].
static func sidecar_path(source_path: String) -> String:
    return source_path.get_basename() + SIDECAR_SUFFIX


## Where a source image's settings used to live.
static func legacy_sidecar_path(source_path: String) -> String:
    return source_path.get_basename() + LEGACY_SIDECAR_SUFFIX


## Every path a source image's settings may sit at, current one first.
##
## For the callers that have to act on a sidecar as a file rather than as settings — the
## rename path copies them, and has to copy an old one that has not been converted yet.
static func sidecar_paths(source_path: String) -> PackedStringArray:
    return PackedStringArray([sidecar_path(source_path), legacy_sidecar_path(source_path)])


## Whether the file at [param path] is a sidecar this addon wrote.
##
## False for a missing or unreadable file, and false for somebody else's file sitting where
## a sidecar would go. Callers use it before overwriting: the same judgement
## [method save_settings] makes, exposed for the rename path, which writes sidecars without
## going through it.
##
## Reads it as whichever kind its name says it is, so this stays usable on a path that was
## built rather than found.
static func is_sidecar(path: String) -> bool:
    if not FileAccess.file_exists(path):
        return false
    if path.ends_with(LEGACY_SIDECAR_SUFFIX):
        return not _read_json_envelope(path).is_empty()
    return not _read_envelope(path).is_empty()


## Converts [param source_path]'s legacy JSON sidecar into a binary one, and removes it.
##
## Returns true only when a file was actually converted, which is once per image ever.
## Every path that reads a sidecar calls this first, so an old file is picked up by the act
## of opening the image it belongs to rather than by a migration anyone has to run.
##
## [b]The envelope is carried over whole rather than decoded and re-encoded.[/b] What is in
## it may be a version 1 file, which nothing here can turn into a version 2 without the
## dock's registry to hand — and does not need to, since the decoders already read both.
## Copying the envelope keeps the conversion about the container and nothing else, so a file
## that survives this loads exactly as it did before.
##
## Nothing is removed until the new file has been written and read back. The failures are
## all quiet and all leave the old file where it is: a sidecar that could not be converted
## is still a sidecar that loads.
static func migrate_legacy_sidecar(source_path: String) -> bool:
    var legacy := legacy_sidecar_path(source_path)
    if not FileAccess.file_exists(legacy):
        return false

    var envelope := _read_json_envelope(legacy)
    if envelope.is_empty():
        # Somebody else's file wearing the name, or ours and unparseable. Neither is
        # something to convert, and neither is something to delete.
        return false

    var path := sidecar_path(source_path)
    # A binary sidecar already there is the newer record and the one that gets read, so
    # there is nothing to convert. The old file is left alone rather than tidied away —
    # this run did not supersede it, and deleting a file on the strength of a write that
    # happened some other time is not a trade worth making.
    if FileAccess.file_exists(path) and not _read_envelope(path).is_empty():
        return false

    if _write_envelope(path, envelope) != OK:
        push_warning("Image Wrangler: could not convert %s; leaving it alone."
                % legacy.get_file())
        return false

    # To the trash rather than straight out, on the same reasoning the rename path uses:
    # this is the user's file and the conversion is one they never asked for.
    if OS.move_to_trash(ProjectSettings.globalize_path(legacy)) != OK:
        push_warning("Image Wrangler: converted %s to %s, but could not remove the old file."
                % [legacy.get_file(), path.get_file()])
    return true


## Settings loaded from [param source_path]'s sidecar, or [code]null[/code] when
## there is nothing usable there.
##
## Null covers every failure — no file, unreadable, unparseable, written by
## another tool, a newer format version, or simply no block for this operation.
## The caller treats them all the same way, by falling back to defaults.
static func load_settings(source_path: String, operation: IWOperation) -> Resource:
    migrate_legacy_sidecar(source_path)
    var path := sidecar_path(source_path)
    if not FileAccess.file_exists(path):
        return null

    var envelope := _read_envelope(path)
    if envelope.is_empty():
        return null
    if int(envelope.get("version", 0)) > VERSION:
        push_warning("Image Wrangler: %s was written by a newer version; ignoring it." % path.get_file())
        return null

    var operations: Dictionary = envelope.get("operations", {})
    var id := String(operation.get_operation_id())
    if not operations.has(id):
        return null

    var settings := operation.make_settings()
    if settings == null:
        return null
    apply_dict(settings, operations[id])
    # Everything above is shape-agnostic, which is what makes the codec generic —
    # and also what leaves it unable to notice that a property changed shape
    # between versions. This is the one place a settings Resource gets to look at
    # what it just loaded and put an older file's values where they now live.
    if settings.has_method("migrate_loaded"):
        settings.call("migrate_loaded")
    return settings


## Writes [param settings] into [param source_path]'s sidecar under this
## operation's id, leaving any other operation's block alone.
##
## Returns [code]OK[/code], or a failure code. Refuses [code]ERR_FILE_CORRUPT[/code]
## when a file of that name already exists and was written by something else. Unlikely
## now that the name carries [constant SIDECAR_SUFFIX], and kept because unlikely is not
## the same as impossible and the cost of being wrong is somebody else's file.
static func save_settings(source_path: String, operation: IWOperation, settings: Resource) -> Error:
    migrate_legacy_sidecar(source_path)
    var path := sidecar_path(source_path)
    var envelope := {}

    if FileAccess.file_exists(path):
        envelope = _read_envelope(path)
        if envelope.is_empty():
            # Present but not ours, or not parseable. Either way it is somebody
            # else's file and overwriting it would destroy their data.
            return ERR_FILE_CORRUPT

    var operations: Dictionary = envelope.get("operations", {})
    operations[String(operation.get_operation_id())] = to_dict(settings)
    envelope["format"] = FORMAT
    envelope["version"] = VERSION
    envelope["operations"] = operations

    return _write_envelope(path, envelope)


# --- The stack ----------------------------------------------------------

## The stack saved for [param source_path], or an empty Array when there is nothing
## usable there.
##
## Each element is [code]{"id": StringName, "enabled": bool, "settings": Resource}[/code].
## [param registry] maps an operation id to its script, so this can build the right
## settings object for each entry; the dock supplies it, since the list of stack
## operations belongs to the dock rather than to the codec.
##
## An id the registry does not know is skipped with a warning rather than failing the
## whole file — a sidecar written by a build with an extra operation should still open
## with everything else intact.
##
## A version 1 file is translated on the way in; see [method _stack_from_v1]. Nothing
## is written back until the user edits something, so opening an old file and closing
## it again leaves it alone.
static func load_stack(source_path: String, registry: Dictionary) -> Array:
    # The one place every opened image passes through, so it is where an old file gets
    # noticed. Converted before it is read rather than after, so there is only ever the one
    # decoder pointed at the one kind of file.
    migrate_legacy_sidecar(source_path)
    var path := sidecar_path(source_path)
    if not FileAccess.file_exists(path):
        return []
    return decode_stack(_read_envelope(path), registry, path.get_file())


## The stack an envelope describes, whatever it arrived in.
##
## Split out from [method load_stack] because the sidecar is no longer the only thing
## carrying a stack: Copy Stack puts this same envelope on the clipboard, and a stack
## pasted from there has to be read on exactly the terms one loaded from a file is —
## same version handling, same retired ids, same skipping of an operation this build
## does not have. Two decoders would only ever disagree.
##
## [param source] names where the envelope came from, for the warnings alone.
static func decode_stack(envelope: Dictionary, registry: Dictionary, source: String) -> Array:
    if envelope.is_empty():
        return []
    var version := int(envelope.get("version", 0))
    if version > VERSION:
        push_warning("Image Wrangler: %s was written by a newer version; ignoring it." % source)
        return []
    if version < 2:
        return _stack_from_v1(envelope, registry)

    var stack := []
    var retired := []
    for element: Variant in envelope.get("stack", []):
        if not (element is Dictionary):
            continue
        var entry: Dictionary = element
        var id := StringName(entry.get("id", ""))
        # First, so the rest only ever sees ids this build uses.
        if _RENAMED_IDS.has(id):
            id = _RENAMED_IDS[id]
        if _RETIRED_IDS.has(id):
            # Held rather than dropped: its settings belong to whatever absorbed it, and
            # that entry may not have been read yet.
            retired.append(entry)
            continue
        if not registry.has(id):
            push_warning("Image Wrangler: %s names an unknown operation \"%s\"; skipping it."
                    % [source, id])
            continue
        var settings := _settings_for_id(id, registry)
        if settings == null:
            continue
        var stored: Variant = entry.get("settings", {})
        if stored is Dictionary:
            apply_dict(settings, stored)
        if settings.has_method("migrate_loaded"):
            settings.call("migrate_loaded")
        stack.append({
            "id": id,
            "enabled": bool(entry.get("enabled", true)),
            "folded": bool(entry.get("folded", false)),
            "settings": settings,
        })
        # A file written while the crevice rule lived inside the background flood keeps
        # its two values in that block, where nothing reads them any more. They become
        # the stage they now belong to, directly below the one they were part of, which
        # is where they were acting.
        if id == &"remove_background" and stored is Dictionary:
            var split := _crevice_from_block(stored, registry)
            if not split.is_empty():
                stack.append(split)

    _absorb_retired(stack, retired)
    return stack


## A [code]remove_crevice[/code] stack entry carrying what an older
## [code]remove_background[/code] block was using the crevice rule for, or an empty
## Dictionary when it was not using it.
##
## A reach of zero is left alone rather than turned into a switched-off stage: it was
## the default and it meant the rule was not in play, so there is nothing to carry and
## an entry that does nothing is still an entry to read past.
static func _crevice_from_block(block: Dictionary, registry: Dictionary) -> Dictionary:
    var reach: Variant = block.get("crevice_reach", 0)
    if not (reach is float or reach is int) or int(reach) <= 0:
        return {}
    if not registry.has(&"remove_crevice"):
        return {}
    var settings := _settings_for_id(&"remove_crevice", registry)
    if settings == null:
        return {}
    settings.crevice_reach = int(reach)
    var tolerance: Variant = block.get("crevice_tolerance", null)
    if tolerance is float or tolerance is int:
        settings.crevice_tolerance = float(tolerance)
    return {"id": &"remove_crevice", "enabled": true, "settings": settings}


## Folds a retired operation's settings into whichever one took its job over.
##
## Applied straight onto the target's settings Resource, which works because the
## properties kept their names when they moved — the codec would have refused them on
## the way in, since the settings object they were read into no longer has them.
##
## A retired entry that was switched off contributes nothing, and one whose target is
## not in the stack has nowhere to go; both are dropped.
static func _absorb_retired(stack: Array, retired: Array) -> void:
    for entry: Dictionary in retired:
        if not bool(entry.get("enabled", true)):
            continue
        var target: StringName = _RETIRED_IDS[StringName(entry.get("id", ""))]
        var stored: Variant = entry.get("settings", {})
        if not (stored is Dictionary):
            continue
        for record: Dictionary in stack:
            if record["id"] == target:
                apply_dict(record["settings"], stored)
                break


## Writes [param stack] into [param source_path]'s sidecar, leaving anything else in
## the file alone.
##
## Returns [code]OK[/code], or a failure code. Refuses [code]ERR_FILE_CORRUPT[/code]
## when a file of that name already exists and was written by something else. See
## [method save_settings] for why that check survives [constant SIDECAR_SUFFIX].
static func save_stack(source_path: String, stack: Array) -> Error:
    migrate_legacy_sidecar(source_path)
    var path := sidecar_path(source_path)
    var envelope := {}

    if FileAccess.file_exists(path):
        envelope = _read_envelope(path)
        if envelope.is_empty():
            # Present but not ours, or not parseable. Either way it is somebody
            # else's file and overwriting it would destroy their data.
            return ERR_FILE_CORRUPT

    envelope["format"] = FORMAT
    envelope["version"] = VERSION
    envelope["stack"] = encode_stack(stack)
    # The version 1 blocks are dropped rather than kept in step. Two records of the
    # same settings would only ever disagree, and the file has already been read.
    envelope.erase("operations")

    return _write_envelope(path, envelope)


## One JSON block per stage, in order, for the [code]"stack"[/code] field.
##
## [param stack] is the dock's own record shape — [code]{"id", "enabled", "folded",
## "settings"}[/code] — and any other key on a record, such as the live operation the
## dock hangs off it, is ignored rather than encoded.
##
## [code]folded[/code] needs no version bump, because the reader takes it with a default
## and a file written before it existed simply comes back unfolded.
static func encode_stack(stack: Array) -> Array:
    var encoded := []
    for entry: Dictionary in stack:
        var settings: Resource = entry.get("settings")
        encoded.append({
            "id": String(entry.get("id", &"")),
            "enabled": bool(entry.get("enabled", true)),
            "folded": bool(entry.get("folded", false)),
            "settings": to_dict(settings),
        })
    return encoded


# --- The clipboard ------------------------------------------------------

## [param stack] as the text Copy Stack and Save Stack write out.
##
## Deliberately the sidecar's own envelope, written out as JSON. It costs nothing — the
## encoder was already there — and it means a copied stack is a saved stack: it can be kept
## in a note, or read, or sent to somebody. A second format would have been a second thing
## to keep in step with every operation added.
##
## [b]Text where the sidecar is binary, and for the same reason each is what it is.[/b] A
## sidecar is written by the dock and read by the dock, so it may as well be small and
## exact; this one goes on the clipboard and into files people open, where being readable is
## the whole point. Both sides use the same encoder, so they cannot drift apart.
##
## [param indent] is empty for the clipboard, where the tabs would only be there to be
## scrolled past, and a tab for a file somebody may open and edit.
static func stack_to_text(stack: Array, indent := "") -> String:
    return JSON.stringify({
        "format": FORMAT,
        "version": VERSION,
        "stack": encode_stack(stack),
    }, indent)


## The stack a bare list of encoded records describes.
##
## The list [method encode_stack] produces, read back. Used by the undo history, which
## keeps states rather than files and has no envelope to put them in — and which needs
## the same decoder as everything else so a recorded state and a saved one cannot come
## back meaning different things.
static func decode_stack_records(encoded: Array, registry: Dictionary, source: String) -> Array:
    return decode_stack({"version": VERSION, "stack": encoded}, registry, source)


## The stack [param text] describes, or an empty Array when it is not one of ours.
##
## Quiet about text that is simply not a stack — the clipboard holds whatever the user
## last copied anywhere, and most of the time that is not this. An envelope that *is*
## ours but names an operation this build does not have still warns, because that one is
## a real mismatch worth knowing about.
static func stack_from_text(text: String, registry: Dictionary) -> Array:
    return decode_stack(_parse_envelope(text), registry, "the clipboard")


## Builds the equivalent stack from a version 1 envelope.
##
## Version 1 knew one fused operation with thirteen tunables. Each stage takes the
## ones that became its own, and a stage whose settings say it was doing nothing is
## left out entirely rather than added switched off — an entry that does nothing is
## still an entry to read past.
static func _stack_from_v1(envelope: Dictionary, registry: Dictionary) -> Array:
    var operations: Variant = envelope.get("operations", {})
    if not (operations is Dictionary):
        return []
    var block: Variant = (operations as Dictionary).get("remove_background", {})
    if not (block is Dictionary):
        return []
    var old: Dictionary = block

    # Decoded into the pre-split shape first, so the values arrive typed and the
    # island migration inside it still gets its chance to run.
    var legacy := _LegacyV1Settings.new()
    apply_dict(legacy, old)
    legacy.migrate_loaded()

    var stack := []
    for id: StringName in _V1_ORDER:
        if not registry.has(id):
            continue
        if not _v1_wants(id, legacy):
            continue
        var settings := _settings_for_id(id, registry)
        if settings == null:
            continue
        _v1_fill(id, legacy, settings)
        stack.append({"id": id, "enabled": true, "settings": settings})
    return stack


## Whether a version 1 file was actually using the stage [param id] stands for.
static func _v1_wants(id: StringName, old: _LegacyV1Settings) -> bool:
    match id:
        &"remove_background":
            return true
        &"polygon_edit":
            return old.polygons != null and not old.polygons.regions.is_empty()
        &"island_picker":
            return old.islands != null and not old.islands.entries.is_empty()
        &"remove_crevice":
            return old.crevice_reach > 0
        &"refine_edges":
            # The clip was usable without the filter, so either one counts.
            return old.refine_edges or old.alpha_floor > 0.0 or old.alpha_ceiling < 1.0
        &"edge_cleanup":
            return old.edge_cleanup
    return false


## Copies the version 1 values a stage inherited into its own settings.
static func _v1_fill(id: StringName, old: _LegacyV1Settings, into: Resource) -> void:
    match id:
        &"remove_background":
            into.remove_colors = old.remove_colors
            into.edge_width = old.edge_width
            into.contiguous = old.contiguous
            into.decontaminate = old.decontaminate
            into.bleed_radius = old.bleed_radius
        &"polygon_edit":
            into.polygons = old.polygons
        &"island_picker":
            into.islands = old.islands
        &"remove_crevice":
            into.crevice_reach = old.crevice_reach
            into.crevice_tolerance = old.crevice_tolerance
        &"refine_edges":
            # A radius of zero is what "the filter was off" became, so a file that
            # only wanted the clip keeps only the clip.
            into.refine_radius = old.refine_radius if old.refine_edges else 0
            into.alpha_floor = old.alpha_floor
            into.alpha_ceiling = old.alpha_ceiling
        &"edge_cleanup":
            into.inner_stroke_width = old.inner_stroke_width
            into.outer_stroke_width = old.outer_stroke_width
            into.stroke_softness = old.stroke_softness
            into.auto_stroke_color = old.auto_stroke_color
            into.stroke_color = old.stroke_color


## A blank settings Resource for [param id], via the registry's script.
static func _settings_for_id(id: StringName, registry: Dictionary) -> Resource:
    var script: Variant = registry.get(id)
    if not (script is Script):
        return null
    var operation: IWOperation = (script as Script).new()
    return operation.make_settings()


## Envelope read back out of a binary sidecar, or an empty Dictionary when the file is
## missing, unreadable, not one of ours, or written by a newer container than this knows.
##
## [b]The magic is checked before anything is decoded.[/b] [method FileAccess.get_var] on
## arbitrary bytes is not something to do hopefully, and four bytes at the front settle it.
## Objects are refused as well — the default, and worth not changing: a sidecar is data, and
## a file that can name a script is a file that can run one.
static func _read_envelope(path: String) -> Dictionary:
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return {}
    if file.get_length() < MAGIC.length() + 4:
        file.close()
        return {}
    if file.get_buffer(MAGIC.length()).get_string_from_ascii() != MAGIC:
        file.close()
        return {}
    var container := file.get_32()
    if container > CONTAINER_VERSION:
        file.close()
        push_warning("Image Wrangler: %s was written by a newer version; ignoring it."
                % path.get_file())
        return {}
    var parsed: Variant = file.get_var()
    file.close()
    if not (parsed is Dictionary):
        return {}
    var envelope: Dictionary = parsed
    if String(envelope.get("format", "")) != FORMAT:
        return {}
    return envelope


## Writes [param envelope] to [param path] as a binary sidecar.
##
## Verified by reading it back rather than by trusting the write. The one caller that
## cannot afford to be wrong is [method migrate_legacy_sidecar], which deletes the old file
## on the strength of this returning [code]OK[/code] — and a sidecar is small enough that
## proving it landed costs nothing worth counting.
static func _write_envelope(path: String, envelope: Dictionary) -> Error:
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        return FileAccess.get_open_error()
    file.store_buffer(MAGIC.to_ascii_buffer())
    file.store_32(CONTAINER_VERSION)
    file.store_var(envelope)
    var error := file.get_error()
    file.close()
    if error != OK:
        return error
    if _read_envelope(path).is_empty():
        return ERR_FILE_CANT_WRITE
    return OK


## Parsed envelope from a legacy JSON sidecar, or an empty Dictionary when the file is
## missing, unreadable, not JSON, or not one of ours.
static func _read_json_envelope(path: String) -> Dictionary:
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return {}
    var text := file.get_as_text()
    file.close()
    return _parse_envelope(text)


## Parsed envelope, or an empty Dictionary when the text is not JSON or not one of ours.
##
## The format check is what keeps this off somebody else's file, whatever it is called,
## and off whatever the user last copied now that a stack can arrive on the clipboard.
## [constant SIDECAR_SUFFIX] makes the first of those unlikely; it does nothing at all
## about the second.
##
## Parsed through a [JSON] instance rather than [method JSON.parse_string], which prints
## an engine error on anything that is not JSON. That was invisible while the only input
## was a file this addon wrote, and is not now: the clipboard holds whatever was last
## copied anywhere, so a user pressing Paste Stack with a URL on it would get a red line
## in the console for doing something perfectly ordinary. Not being one of ours is an
## answer here, not a fault.
static func _parse_envelope(text: String) -> Dictionary:
    var json := JSON.new()
    if json.parse(text) != OK:
        return {}
    var parsed: Variant = json.data
    if not (parsed is Dictionary):
        return {}
    var envelope: Dictionary = parsed
    if String(envelope.get("format", "")) != FORMAT:
        return {}
    return envelope


# --- Codec --------------------------------------------------------------

## Every stored property of [param resource], encoded for JSON.
##
## The usage filter is what keeps this to the [code]@export[/code]ed script
## variables and out of [code]resource_path[/code], [code]resource_name[/code]
## and the rest of the Resource machinery.
static func to_dict(resource: Resource) -> Dictionary:
    var data := {}
    if resource == null:
        return data
    for property in resource.get_property_list():
        var usage: int = property.get("usage", 0)
        if not (usage & PROPERTY_USAGE_STORAGE):
            continue
        if not (usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
            continue
        var name: String = property.get("name", "")
        if name.is_empty():
            continue
        data[name] = _encode(resource.get(name))
    return data


## Applies [param data] to [param resource], leaving anything it does not
## mention at whatever the resource already holds.
##
## Decoding is driven by the type of the value already sitting in the target,
## not by inspecting the JSON — which is what lets a typed array keep its element
## type without anyone parsing a property hint string. Keys the resource does not
## have are ignored, so a file from a newer version loads cleanly.
static func apply_dict(resource: Resource, data: Dictionary) -> void:
    if resource == null:
        return
    for property in resource.get_property_list():
        var usage: int = property.get("usage", 0)
        if not (usage & PROPERTY_USAGE_STORAGE):
            continue
        if not (usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
            continue
        var name: String = property.get("name", "")
        if name.is_empty() or not data.has(name):
            continue
        var current: Variant = resource.get(name)
        var decoded: Variant = _decode(current, data[name])
        # _decode returns the target untouched when the stored value is the
        # wrong shape, so a single malformed entry costs that one setting rather
        # than the whole file.
        if decoded != null:
            resource.set(name, decoded)


## [b]Every type a setting may hold has to be named in all three of [method _encode],
## [method _decode] and [method _blank_element].[/b] A type missing from the first two
## falls through to being returned as-is, which for a struct means Godot's own
## [code]to_string[/code] — so it saves as something like
## [code]"[P: (20, 30), S: (40, 50)]"[/code] and decodes back to the blank, silently. The
## setting is then not merely unsaved: it is unsaved and reads as its default, which looks
## like the operation doing nothing rather than like a codec that dropped it.
static func _encode(value: Variant) -> Variant:
    match typeof(value):
        TYPE_COLOR:
            var color: Color = value
            return [color.r, color.g, color.b, color.a]
        TYPE_VECTOR2I:
            var point: Vector2i = value
            return [point.x, point.y]
        TYPE_VECTOR2:
            var spot: Vector2 = value
            return [spot.x, spot.y]
        TYPE_RECT2I:
            var box: Rect2i = value
            return [box.position.x, box.position.y, box.size.x, box.size.y]
        TYPE_ARRAY:
            var encoded := []
            for item in (value as Array):
                encoded.append(_encode(item))
            return encoded
        TYPE_OBJECT:
            return to_dict(value as Resource)
    return value


## The stored value converted to match [param target]'s type, or [param target]
## itself when the stored value cannot be read that way.
static func _decode(target: Variant, encoded: Variant) -> Variant:
    match typeof(target):
        TYPE_BOOL:
            return bool(encoded) if encoded is bool else target
        TYPE_INT:
            return int(encoded) if (encoded is float or encoded is int) else target
        TYPE_FLOAT:
            return float(encoded) if (encoded is float or encoded is int) else target
        TYPE_STRING:
            return String(encoded) if encoded is String else target
        TYPE_VECTOR2I:
            if not (encoded is Array) or (encoded as Array).size() < 2:
                return target
            var pair: Array = encoded
            return Vector2i(int(pair[0]), int(pair[1]))
        TYPE_VECTOR2:
            if not (encoded is Array) or (encoded as Array).size() < 2:
                return target
            var spot: Array = encoded
            return Vector2(float(spot[0]), float(spot[1]))
        TYPE_RECT2I:
            if not (encoded is Array) or (encoded as Array).size() < 4:
                return target
            var box: Array = encoded
            return Rect2i(int(box[0]), int(box[1]), int(box[2]), int(box[3]))
        TYPE_COLOR:
            if not (encoded is Array) or (encoded as Array).size() < 4:
                return target
            var channels: Array = encoded
            return Color(float(channels[0]), float(channels[1]), float(channels[2]), float(channels[3]))
        TYPE_ARRAY:
            if not (encoded is Array):
                return target
            # duplicate() then clear() keeps the array's element type, so the
            # appends below stay typed without anyone reading a hint string.
            var out: Array = (target as Array).duplicate()
            out.clear()
            for item in (encoded as Array):
                # A fresh blank per item, not one hoisted out of the loop. For a
                # primitive that is the same value either way, but an object blank
                # is decoded into *in place* — reusing one would append the same
                # instance under every index and every entry would read alike.
                out.append(_decode(_blank_element(target as Array), item))
            return out
        TYPE_OBJECT:
            if not (encoded is Dictionary) or target == null:
                return target
            apply_dict(target as Resource, encoded as Dictionary)
            return target
    return target


## A zero value of [param array]'s element type, to decode each item against.
##
## For an array of Resources that means a real instance at its own defaults,
## built from the element script the array is typed to. Without it a stored entry
## would decode against [code]null[/code] and come back as null, so an
## [code]Array[RemoveColorEntry][/code] would survive a save as a row of nothing.
static func _blank_element(array: Array) -> Variant:
    if not array.is_typed():
        return null
    match array.get_typed_builtin():
        TYPE_BOOL: return false
        TYPE_INT: return 0
        TYPE_FLOAT: return 0.0
        TYPE_STRING: return ""
        TYPE_VECTOR2I: return Vector2i.ZERO
        TYPE_VECTOR2: return Vector2.ZERO
        TYPE_RECT2I: return Rect2i()
        TYPE_COLOR: return Color.WHITE
        TYPE_OBJECT:
            var element_script: Variant = array.get_typed_script()
            if element_script is Script:
                return (element_script as Script).new()
    return null


## Round-trips a settings Resource through the codec and reports any property
## that does not survive.
##
## The reflective path is the one part of this addon that cannot be reasoned
## about from source alone — it depends on property usage flags and typed-array
## behaviour. Called from [code]plugin.gd[/code] behind a constant so the first
## real run can turn it on and get an unmissable failure.
static func self_test(operation: IWOperation) -> bool:
    var original := operation.make_settings()
    var restored := operation.make_settings()
    if original == null or restored == null:
        push_error("Image Wrangler self-test: operation has no settings to test.")
        return false

    # Drive every property away from its default, so a value that fails to
    # round-trip cannot coincidentally match.
    for property in original.get_property_list():
        var usage: int = property.get("usage", 0)
        if not (usage & PROPERTY_USAGE_STORAGE) or not (usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
            continue
        var name: String = property.get("name", "")
        match typeof(original.get(name)):
            TYPE_BOOL: original.set(name, not bool(original.get(name)))
            TYPE_INT: original.set(name, int(original.get(name)) + 7)
            TYPE_FLOAT: original.set(name, float(original.get(name)) + 0.125)
            TYPE_COLOR: original.set(name, Color(0.25, 0.5, 0.75, 1.0))
            TYPE_OBJECT:
                var nested := original.get(name)
                if nested is IslandList:
                    var islands := nested as IslandList
                    islands.clear()
                    islands.add(Vector2i(128, 64))
                    # A dragged region as well as a single click, since an entry is
                    # a group of picks now: a decoder that dropped the inner list,
                    # or handed every entry the same one, would round-trip a
                    # one-pick island without complaint.
                    var picked := islands.add_region(Rect2i(3, 900, 3, 2))
                    # Driven off the defaults on every count, so an entry that
                    # failed to round-trip cannot coincidentally match — and the two
                    # picks driven apart from each other, for the reason the colour
                    # list's two entries are.
                    picked.enabled = false
                    picked.mode = IWAlphaMode.Mode.ADD
                    picked.get_pick(0).color_tolerance = 0.077
                    picked.get_pick(picked.size() - 1).color_tolerance = 0.311
                elif nested is RemoveColorList:
                    # Two entries with different tolerances, because one would not
                    # catch a decoder that returned the same instance for every
                    # index — the failure an array of Resources invites.
                    var colors := nested as RemoveColorList
                    colors.clear()
                    colors.add(Color(0.25, 0.5, 0.75), 0.011)
                    colors.add(Color(0.9, 0.1, 0.2), 0.333)
                    # And a swept group, since an entry is a group of colours now:
                    # a decoder that dropped the inner list would round-trip the two
                    # one-colour entries above without complaint. Far enough apart
                    # that the thinning in add_region keeps both.
                    var swept := colors.add_region(
                            PackedColorArray([Color(0.2, 0.4, 0.6), Color(0.7, 0.2, 0.9)]), 0.05)
                    swept.enabled = false
                    swept.get_sample(1).color_tolerance = 0.222
                elif nested is PolygonRegionList:
                    # The deepest nesting this codec has to survive: a typed array
                    # of Vector2i inside a Resource inside a typed array of
                    # Resources. Two regions of different lengths, so a decoder
                    # that reused one instance or one point array shows up as a
                    # length mismatch rather than needing the values compared.
                    var regions := nested as PolygonRegionList
                    regions.clear()
                    var triangle := regions.add()
                    triangle.points = [Vector2i(3, 4), Vector2i(90, 12), Vector2i(40, 77)]
                    triangle.color = Color(0.1, 0.9, 0.4, 1.0)
                    var quad := regions.add()
                    quad.points = [Vector2i(0, 0), Vector2i(8, 0), Vector2i(8, 8), Vector2i(0, 8)]
                    quad.color = Color(0.8, 0.2, 0.6, 1.0)
                    quad.enabled = false
                    quad.mode = IWAlphaMode.Mode.ADD
                elif nested is BrushStrokeList:
                    # The same nesting depth the polygons reach, and checked as well
                    # rather than instead: a stroke carries two tunables of its own
                    # beside the path, so a decoder that rebuilt the list but handed
                    # every stroke the default brush would round-trip the polygons
                    # without complaint and quietly flatten every stroke here.
                    var painted := nested as BrushStrokeList
                    painted.clear()
                    var dab := painted.add(3, 0.25)
                    dab.points = [Vector2i(11, 12)]
                    dab.color = Color(0.2, 0.7, 0.3, 1.0)
                    var sweep := painted.add(17, 0.8)
                    sweep.points = [Vector2i(0, 0), Vector2i(5, 9), Vector2i(40, 41)]
                    sweep.color = Color(0.7, 0.3, 0.9, 1.0)
                    sweep.enabled = false
                    sweep.mode = IWAlphaMode.Mode.ADD

    var round_tripped: Variant = JSON.parse_string(JSON.stringify(to_dict(original)))
    if not (round_tripped is Dictionary):
        push_error("Image Wrangler self-test: encoded settings did not survive JSON.")
        return false
    apply_dict(restored, round_tripped)

    var passed := true
    for property in original.get_property_list():
        var usage: int = property.get("usage", 0)
        if not (usage & PROPERTY_USAGE_STORAGE) or not (usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
            continue
        var name: String = property.get("name", "")
        var before: Variant = original.get(name)
        var after: Variant = restored.get(name)
        if before is Resource:
            # Compared through the codec rather than by identity, since two
            # Resources holding identical values are never the same object. This
            # is the only comparison that reaches inside a nested list.
            var before_dict := JSON.stringify(to_dict(before as Resource))
            var after_dict := JSON.stringify(to_dict(after as Resource) if after is Resource else {})
            if before_dict != after_dict:
                push_error("Image Wrangler self-test: %s did not round-trip (%s vs %s)."
                        % [name, before_dict, after_dict])
                passed = false
        elif before != after:
            push_error("Image Wrangler self-test: %s did not round-trip (%s vs %s)." % [name, before, after])
            passed = false
    return passed
