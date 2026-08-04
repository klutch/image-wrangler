@tool
class_name IWComfyInstall
extends RefCounted

## Works out how a ComfyUI folder is laid out, so the dock can start it.
##
## Three layouts are recognised: Krita AI Diffusion's managed server, the portable build,
## and a stock clone. See [method resolve].

## Where an interpreter sits under a folder, in the order they are looked for. The last two
## are the portable build, whose python is not in a virtual environment.
const PYTHON_TAILS := ["Scripts/python.exe", "bin/python", "python.exe", "python"]


## What [param root] holds: [code]found[/code], [code]kind[/code], [code]main[/code],
## [code]python[/code] and a [code]note[/code] fit for a label.
##
## Only true when both a main.py and an interpreter turned up, since neither alone can start
## anything. The note is always set, success included.
static func resolve(root: String) -> Dictionary:
    var tidy := root.strip_edges().replace("\\", "/").rstrip("/")
    if tidy.is_empty():
        return _miss("No folder yet. Pick the one ComfyUI was installed into.")
    if not DirAccess.dir_exists_absolute(tidy):
        return _miss("%s is not there any more." % tidy)

    # Krita's managed server and the portable build both nest main.py one level down, and
    # differ only in where the interpreter is.
    var nested := tidy + "/ComfyUI/main.py"
    if FileAccess.file_exists(nested):
        var managed := _python(tidy + "/venv")
        if not managed.is_empty():
            return _hit(&"krita", nested, managed, "Krita's managed ComfyUI.")
        var portable := _python(tidy + "/python_embeded")
        if not portable.is_empty():
            return _hit(&"portable", nested, portable, "Portable ComfyUI.")
        return _miss("Found ComfyUI/main.py but no Python. Looked in venv and python_embeded.")

    var stock := tidy + "/main.py"
    if FileAccess.file_exists(stock):
        # One folder up as well, because browsing straight to the folder holding main.py is
        # the mistake that is actually made.
        var up := tidy.get_base_dir()
        for where: String in [tidy + "/venv", tidy + "/.venv", up + "/venv",
                up + "/python_embeded"]:
            var python := _python(where)
            if not python.is_empty():
                return _hit(&"stock", stock, python, "ComfyUI, with Python in %s."
                        % where.trim_prefix(up + "/"))
        return _miss("Found main.py but no Python. Looked in venv, .venv, and one folder up.")

    return _miss("No main.py in %s or in a ComfyUI folder inside it." % tidy.get_file())


## The interpreter under [param dir], or empty.
static func _python(dir: String) -> String:
    for tail: String in PYTHON_TAILS:
        var path := "%s/%s" % [dir, tail]
        if FileAccess.file_exists(path):
            return path
    return ""


static func _hit(kind: StringName, main: String, python: String, note: String) -> Dictionary:
    return {"found": true, "kind": kind, "main": main, "python": python, "note": note}


static func _miss(note: String) -> Dictionary:
    return {"found": false, "kind": &"", "main": "", "python": "", "note": note}
