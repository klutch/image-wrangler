@tool
class_name RenameSettings
extends Resource

## Every tunable of [Rename].
##
## Unlike the other settings here these are not per-image and are never written
## to a sidecar. A rename scheme describes the batch rather than any one file —
## a counter that restarted per image would be meaningless — so one set is held
## for as long as the dock is open and every image is named by it.
## [method IWOperation.settings_are_per_image] is what says so.

## Where the counter goes in the finished name.
enum NumberAt { END, START }

## What to do to the letters of the finished name.
enum LetterCase { UNCHANGED, LOWER, UPPER, TITLE }

## Replaces each file's own name. Left empty, every file keeps its own, which is
## what makes find-and-replace and numbering useful on a mixed batch.
@export var base_name: String = ""

## Text to look for in the name. Empty disables the replacement entirely, so an
## empty [member replace_with] cannot silently strip anything.
@export var find: String = ""

## What [member find] becomes. Empty deletes the matched text.
@export var replace_with: String = ""

## Goes in front of the finished name, ahead of any number.
@export var prefix: String = ""

## Counter value for the first file in the list.
@export var start_at: int = 1

## How much the counter moves per file.
@export var step: int = 1

## Zero-pads the counter to at least this many digits, so names sort correctly in
## a file browser. Every file is numbered by its position in the list.
@export var digits: int = 3

## Which end of the name the counter goes on. See [enum NumberAt].
@export var number_at: int = NumberAt.END

## Text between the name and the counter.
@export var separator: String = "_"

## See [enum LetterCase]. Applied to the whole finished name, never to the
## extension.
@export var letter_case: int = LetterCase.UNCHANGED

## Lowercase the extension, so a folder of .PNG and .png files comes out
## consistent.
@export var lowercase_extension: bool = true

## Offer to delete each source once its copy has been written and checked.
##
## Off by default, and deliberately never automatic: the dock asks first, then
## proves every copy matches its source by checksum before anything is deleted,
## and sends the originals to the system trash rather than unlinking them.
@export var remove_old_files: bool = false
