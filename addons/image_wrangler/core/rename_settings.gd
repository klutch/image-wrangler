@tool
class_name RenameSettings
extends Resource

## Every tunable of [Rename], in one object the dock can swap.
##
## Like all settings here these belong to the image on screen, which is a little
## unusual for a batch rename: dialling in a scheme and then selecting a file
## that has its own saved settings will show that file's scheme instead. The
## carry-over rule means a run of untouched images all share whatever was last
## dialled in, which is the case that matters.

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

## Number each file according to its position in the list.
@export var numbering: bool = false

## Counter value for the first file in the list.
@export var start_at: int = 1

## How much the counter moves per file.
@export var step: int = 1

## Zero-pads the counter to at least this many digits, so names sort correctly in
## a file browser.
@export var digits: int = 3

## Which end of the name the counter goes on. See [enum NumberAt].
@export var number_at: int = NumberAt.END

## Text between the name and the counter. Ignored when numbering is off.
@export var separator: String = "_"

## See [enum LetterCase]. Applied to the whole finished name, never to the
## extension.
@export var letter_case: int = LetterCase.UNCHANGED

## Lowercase the extension, so a folder of .PNG and .png files comes out
## consistent.
@export var lowercase_extension: bool = true


## A copy that belongs to another image.
##
## Nothing here is positional the way an island coordinate is, so unlike
## [RemoveBackgroundSettings] a plain duplicate carries everything.
func duplicate_for_new_image() -> RenameSettings:
	return duplicate()
