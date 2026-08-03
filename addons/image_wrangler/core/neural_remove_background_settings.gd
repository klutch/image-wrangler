@tool
class_name NeuralRemoveBackgroundSettings
extends Resource

## Every tunable of [NeuralRemoveBackground].
##
## Ranges live in [method NeuralRemoveBackground.get_settings_schema], not here.

## What writes the alpha once the network has said what is subject.
enum MatteSource {
    ## The analytic matte: one background colour is sampled off the image, and the
    ## edge is recovered against it exactly as Remove Background recovers its own.
    ANALYTIC,
    ## The network's own probability, stretched over the image, as the alpha directly.
    NETWORK_ALPHA,
}

## Where a model goes unless told otherwise, as a path inside the addon.
##
## Beside the rest of the addon's gitignored third-party folders, and empty in a fresh
## checkout — no model ships here. Download Latest Model is what fills it.
const MODEL_SUBDIR := "res://addons/image_wrangler/thirdparty/isnet-general"

## Where the converted model can be fetched from, and roughly what the archive weighs.
## Carried on the Model Folder schema entry; see [IWModelFolder].
##
## The weight is the archive rather than the model inside it, because it is only ever used
## to move a progress bar — and a forge builds a source archive as it serves it, so there is
## no length in the header to measure against. The model unpacks to about 88 MB.
const MODEL_URL := "https://github.com/klutch/isnet-general-ncnn/archive/refs/tags/main-release.zip"
const MODEL_BYTES := 81463556


## The same folder as something that can be opened.
##
## [b]Absolute rather than [code]res://[/code].[/b] The network reads the two files through
## the C runtime rather than through Godot, so it cannot be handed a [code]res://[/code] path
## at all — and a folder shown in the dock should be one that can be pasted into a file
## browser.
static func default_model_dir() -> String:
    return ProjectSettings.globalize_path(MODEL_SUBDIR)


## The folder holding the converted model the network runs.
##
## [b]Empty means [method default_model_dir].[/b] It is not a folder anyone chose — it is
## what a settings file written before this had a default says, and what clearing the field
## leaves behind. Both mean the same thing: put the model where the model goes.
@export var model_dir: String = default_model_dir()

## How sure the network has to be before a pixel counts as subject, 0 to 1.
@export var threshold: float = 0.5

## Only remove background the image border can reach, so pockets enclosed by the subject
## (highlights, eyes, gaps in lettering) stay opaque even when the network cuts them out.
@export var contiguous: bool = true

## Width of the antialiased band, in pixels. Same meaning as Remove Background's.
@export var edge_width: int = 2

## Tolerance around the sampled background colour when the edge is recovered against it.
@export var edge_tolerance: float = 0.0

## Un-blend the background out of partially transparent pixels.
@export var decontaminate: bool = true

## How far subject colour is pushed into transparent pixels, in pixels.
@export var bleed_radius: int = 16

## A [enum MatteSource] index: what writes the alpha.
@export var matte_source: int = MatteSource.ANALYTIC


## Why the last run made nothing, or empty when it ran.
##
## [b]Deliberately not exported.[/b] An observation about one run rather than part of what
## the operation is, so the codec leaves it out. Carried home by
## [method NeuralRemoveBackground.absorb_run_report].
var last_error := ""

## How much of the image the network called subject on the last run, 0 to 1. Negative
## until a run has said.
var last_subject_fraction := -1.0

## Whether a run has reported yet, so the readouts can say "—" rather than lying.
var has_run := false


## What the network made of the image, as a line for the form to show.
func subject_text() -> String:
    if not has_run or last_subject_fraction < 0.0:
        return "—"
    return "%d%% of the image" % roundi(last_subject_fraction * 100.0)


## Why there is nothing to show, as a line for the form to show.
func status_text() -> String:
    if not has_run:
        return "—"
    return "ok" if last_error.is_empty() else last_error


## A copy that belongs to no image. Nothing here is a coordinate and nothing is a nested
## Resource, so the plain duplicate is the whole of it.
func duplicate_for_new_image() -> NeuralRemoveBackgroundSettings:
    return duplicate()
