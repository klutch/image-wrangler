@tool
class_name IWComfyServer
extends Node

## The dock's side of a conversation with a ComfyUI server.
##
## A Node rather than a plain object because everything it does needs the tree:
## [HTTPRequest] is a Node and refuses to start outside one, and the run has to survive
## across frames.
##
## [b]The run is confirmed by asking, never by being told.[/b] A job is submitted, then
## [code]/history[/code] is polled until it says the job finished. Anything pushed at us is
## only ever used to move a progress bar sooner.

## Where a fresh dock looks first. ComfyUI's own default.
const DEFAULT_URL := "http://127.0.0.1:8188"

## How long each kind of request may take. Fetching a picture is slower than asking a
## question, and a picture can be a few megabytes over loopback.
const ASK_TIMEOUT := 10.0
const FETCH_TIMEOUT := 60.0

## How often the run is asked whether it has finished.
const POLL_SECONDS := 1.0

## How many polls in a row may fail before the run is called lost.
##
## More than one, deliberately. A single dropped request over loopback while the graphics
## card is pinned is ordinary, and calling that a crash would be wrong far more often than
## it was right.
const POLL_FAILURES_ALLOWED := 3

## How long a run may go without a sign of life before it is let go, in seconds.
const STALL_SECONDS := 180.0

enum State { OFFLINE, READY, RUNNING }

## Emitted when the server comes or goes, or a run starts or stops. See [enum State].
signal state_changed(state: int)

## Emitted once the server has said what models and samplers it has. Carries
## [code]checkpoints[/code], [code]loras[/code], [code]samplers[/code] and
## [code]schedulers[/code], each an Array of names.
signal info_ready(lists: Dictionary)

## Emitted as a run goes along. [param fraction] is -1.0 when there is nothing to measure,
## which is most of a run until the pictures start coming back.
signal progress(fraction: float, note: String)

## Emitted when a run finishes, with one [Image] per picture made.
signal finished(images: Array)

## Emitted when a run could not be made or could not be finished. [param reason] is one
## sentence fit for a status line.
signal failed(reason: String)

var _url := DEFAULT_URL
var _state := State.OFFLINE

## Bumped for every run. Every reply carries the number it was asked under, so an answer
## belonging to a run that has already been abandoned is dropped rather than acted on.
var _run_id := 0

## Set on the way out so a reply arriving after the dock has gone does nothing.
var _shutting_down := false

## What the server last said it has. Kept so a second tab visit does not re-ask.
var _lists := {}


func _exit_tree() -> void:
    shut_down()


# --- What the dock asks of this ------------------------------------------

func set_url(url: String) -> void:
    var tidy := url.strip_edges()
    if tidy.is_empty():
        tidy = DEFAULT_URL
    # Trailing slashes would double up against the paths below.
    while tidy.ends_with("/"):
        tidy = tidy.substr(0, tidy.length() - 1)
    if tidy == _url:
        return
    _url = tidy
    # The old server's answer describes a machine we are no longer talking to.
    _lists = {}
    _set_state(State.OFFLINE)


func url() -> String:
    return _url


func state() -> int:
    return _state


func is_running() -> bool:
    return _state == State.RUNNING


## Whether the server has already said what it has.
func has_lists() -> bool:
    return not _lists.is_empty()


## Asks whether the server is there, and what it has.
##
## Safe to call on every visit to the tab. A server already known and answering is not
## asked for its lists again — only a reconnection is.
func probe() -> void:
    if _shutting_down or _state == State.RUNNING:
        return
    var reply := await _ask(_url + "/system_stats", ASK_TIMEOUT)
    if _shutting_down:
        return
    if not reply["ok"]:
        _lists = {}
        _set_state(State.OFFLINE)
        failed.emit(reply["note"])
        return
    # Something answered. Whether it is ComfyUI is a different question, and one worth
    # asking — another program on that port would otherwise read as a broken ComfyUI.
    if not (reply["json"] is Dictionary) or not (reply["json"] as Dictionary).has("system"):
        _lists = {}
        _set_state(State.OFFLINE)
        failed.emit("Something is answering on %s, but it is not ComfyUI." % _url)
        return

    _set_state(State.READY)
    if _lists.is_empty():
        await _fetch_lists()


## Sends a graph and follows it to its end.
##
## One run at a time. A second press while one is going is refused rather than queued: a
## generation costs a minute of graphics card, and nobody asks for two by accident.
func submit(graph: Dictionary) -> void:
    if _shutting_down or _state == State.RUNNING:
        return
    if _state == State.OFFLINE:
        failed.emit("Not connected to ComfyUI.")
        return

    _run_id += 1
    var run := _run_id
    _set_state(State.RUNNING)
    progress.emit(-1.0, "Sending the job")

    var body := JSON.stringify({"prompt": graph, "client_id": _client_id()})
    var reply := await _send(_url + "/prompt", body, ASK_TIMEOUT)
    if _stale(run):
        return
    if not reply["ok"]:
        _end_run("Could not send the job. %s" % reply["note"])
        return

    var answer: Variant = reply["json"]
    if not (answer is Dictionary) or not (answer as Dictionary).has("prompt_id"):
        _end_run(_submit_refusal(answer))
        return

    await _follow(String((answer as Dictionary)["prompt_id"]), run)


## Drops whatever is in flight. The server is left alone — see the note on Cancel in the
## plan; interrupting is a later job.
func shut_down() -> void:
    _shutting_down = true
    _run_id += 1


# --- Following a run -----------------------------------------------------

## Polls until the job is done, then fetches what it made.
func _follow(prompt_id: String, run: int) -> void:
    progress.emit(-1.0, "Generating")
    var misses := 0
    var waited := 0.0

    while true:
        await get_tree().create_timer(POLL_SECONDS).timeout
        if _stale(run):
            return
        waited += POLL_SECONDS

        var reply := await _ask("%s/history/%s" % [_url, prompt_id], ASK_TIMEOUT)
        if _stale(run):
            return

        if not reply["ok"]:
            misses += 1
            if misses >= POLL_FAILURES_ALLOWED:
                _end_run("ComfyUI stopped answering. It may have run out of memory and closed — check its console.")
                return
            continue
        misses = 0

        var history: Variant = reply["json"]
        if not (history is Dictionary) or not (history as Dictionary).has(prompt_id):
            # Still queued or still working. Nothing is wrong with an empty answer.
            if waited >= STALL_SECONDS:
                # Let go rather than cancelled: the server may well still be working, and
                # saying it was stopped would be a lie.
                _end_run("ComfyUI has not answered for %d minutes. The run was let go — it may still be going, so check its console."
                        % int(STALL_SECONDS / 60.0))
                return
            continue

        var entry: Dictionary = (history as Dictionary)[prompt_id]
        var trouble := _run_trouble(entry)
        if not trouble.is_empty():
            _end_run(trouble)
            return
        var outputs: Dictionary = entry.get("outputs", {})
        if outputs.is_empty():
            continue
        await _collect(outputs, run)
        return


## Why a finished run failed, or empty when it did not.
##
## The traceback ComfyUI sends is enormous and belongs nowhere near a status line, so only
## the failing node and the first line of its message are used.
func _run_trouble(entry: Dictionary) -> String:
    var status: Dictionary = entry.get("status", {})
    if String(status.get("status_str", "")) != "error":
        return ""
    for message in status.get("messages", []):
        if not (message is Array) or (message as Array).size() < 2:
            continue
        if String((message as Array)[0]) != "execution_error":
            continue
        var detail: Dictionary = (message as Array)[1]
        var node := String(detail.get("node_type", "A node"))
        var first := String(detail.get("exception_message", "")).split("\n")[0]
        var line := "%s failed: %s" % [node, first]
        if String(detail.get("exception_type", "")).contains("OutOfMemory"):
            line += " Try a smaller size."
        return line
    return "The run failed, and ComfyUI did not say why."


## Fetches every picture the run made.
func _collect(outputs: Dictionary, run: int) -> void:
    var wanted := []
    for node_id in outputs:
        for entry in (outputs[node_id] as Dictionary).get("images", []):
            # Temp pictures belong to a preview node somebody else queued.
            if String((entry as Dictionary).get("type", "output")) != "output":
                continue
            wanted.append(entry)

    if wanted.is_empty():
        _end_run("The run finished but made no pictures.")
        return

    var images := []
    var lost := 0
    for i in wanted.size():
        progress.emit(float(i) / float(wanted.size()),
                "Fetching %d of %d" % [i + 1, wanted.size()])
        var image := await _fetch_image(wanted[i])
        if _stale(run):
            return
        if image == null:
            lost += 1
            continue
        images.append(image)

    if images.is_empty():
        _end_run("ComfyUI made the picture but would not hand it over.")
        return

    _set_state(State.READY)
    if lost > 0:
        failed.emit("Got %d of %d pictures; the rest would not come down." % [images.size(), wanted.size()])
    finished.emit(images)


## One picture off the server, or null.
func _fetch_image(entry: Dictionary) -> Image:
    var query := "filename=%s&subfolder=%s&type=%s" % [
        String(entry.get("filename", "")).uri_encode(),
        String(entry.get("subfolder", "")).uri_encode(),
        String(entry.get("type", "output")).uri_encode(),
    ]
    var reply := await _ask("%s/view?%s" % [_url, query], FETCH_TIMEOUT, true)
    if not reply["ok"]:
        return null
    var image := Image.new()
    # Checked rather than assumed: a 404 hands back an error page, and letting that through
    # would put an empty picture on screen as though it were the answer.
    if image.load_png_from_buffer(reply["body"]) != OK or image.is_empty():
        return null
    return image


# --- What the server has -------------------------------------------------

## Asks for the three node descriptions the form's dropdowns are filled from.
##
## Never the whole catalogue: [code]/object_info[/code] on its own is over a megabyte of
## JSON parsed on the main thread, for four lists. One node at a time is under a kilobyte.
func _fetch_lists() -> void:
    var lists := {"checkpoints": [], "loras": [], "samplers": [], "schedulers": []}

    var checkpoint := await _node_info("CheckpointLoaderSimple")
    if _shutting_down:
        return
    lists["checkpoints"] = _options_of(checkpoint, "ckpt_name")

    var lora := await _node_info("LoraLoader")
    if _shutting_down:
        return
    lists["loras"] = _options_of(lora, "lora_name")

    var sampler := await _node_info("KSampler")
    if _shutting_down:
        return
    lists["samplers"] = _options_of(sampler, "sampler_name")
    lists["schedulers"] = _options_of(sampler, "scheduler")

    _lists = lists
    info_ready.emit(lists)


## One node's description, or an empty Dictionary.
func _node_info(node: String) -> Dictionary:
    var reply := await _ask("%s/object_info/%s" % [_url, node], ASK_TIMEOUT)
    if not reply["ok"] or not (reply["json"] is Dictionary):
        return {}
    var all: Dictionary = reply["json"]
    return all.get(node, {})


## The list of names one input offers, or empty.
##
## A combo input arrives as a list nested inside a list: the first element is the options,
## the second whatever else the node had to say about them.
static func _options_of(node: Dictionary, input: String) -> Array:
    var required: Dictionary = node.get("input", {}).get("required", {})
    if not required.has(input):
        return []
    var spec: Variant = required[input]
    if not (spec is Array) or (spec as Array).is_empty():
        return []
    var first: Variant = (spec as Array)[0]
    return first if first is Array else []


# --- Requests ------------------------------------------------------------

## Named [code]_ask[/code] rather than the obvious thing: [code]_get[/code] is [Object]'s
## own property hook, and overriding it with another signature will not compile.
func _ask(url: String, timeout: float, want_bytes := false) -> Dictionary:
    return await _request(url, timeout, HTTPClient.METHOD_GET, "", want_bytes)


func _send(url: String, body: String, timeout: float) -> Dictionary:
    return await _request(url, timeout, HTTPClient.METHOD_POST, body, false)


## One request, made and thrown away. Returns [code]ok[/code], [code]code[/code],
## [code]json[/code], [code]body[/code] and a [code]note[/code] fit for a status line.
##
## A node each rather than one reused: an [HTTPRequest] carries one request at a time, and
## a probe landing on the same node as a run in flight would take the run's reply. These
## are paced by the user rather than by the frame, so a node per call costs nothing worth
## saving.
func _request(url: String, timeout: float, method: int, body: String,
        want_bytes: bool) -> Dictionary:
    if _shutting_down or not is_inside_tree():
        return {"ok": false, "code": 0, "json": null, "body": PackedByteArray(),
                "note": "The dock is closing."}

    var http := HTTPRequest.new()
    http.timeout = timeout
    # Keeps a slow reply off the main thread. The completion still arrives on it.
    http.use_threads = true
    add_child(http)

    var headers := PackedStringArray()
    if not body.is_empty():
        headers.append("Content-Type: application/json")
    var error := http.request(url, headers, method, body)
    if error != OK:
        http.queue_free()
        return {"ok": false, "code": 0, "json": null, "body": PackedByteArray(),
                "note": "Could not reach %s." % url.get_slice("/", 2)}

    var reply: Array = await http.request_completed
    http.queue_free()

    var result: int = reply[0]
    var code: int = reply[1]
    var data: PackedByteArray = reply[3]

    if result != HTTPRequest.RESULT_SUCCESS:
        var note := "No answer from %s." % url.get_slice("/", 2)
        if result == HTTPRequest.RESULT_TIMEOUT:
            note = "%s took too long to answer." % url.get_slice("/", 2)
        return {"ok": false, "code": code, "json": null, "body": data, "note": note}

    var parsed: Variant = null
    if not want_bytes:
        # A JSON instance rather than parse_string, which prints an engine error of its own
        # for anything that is not JSON — and an error page is not.
        var json := JSON.new()
        if json.parse(data.get_string_from_utf8()) == OK:
            parsed = json.data

    if code < 200 or code >= 300:
        return {"ok": false, "code": code, "json": parsed, "body": data,
                "note": "%s answered %d." % [url.get_slice("/", 2), code]}
    return {"ok": true, "code": code, "json": parsed, "body": data, "note": ""}


## Why the server would not take the graph, in one sentence.
##
## A refusal carries an error and a note per node that was wrong. The node's own note is
## the useful half — "Required input is missing: ckpt_name" says what to fix, where the
## outer message only says the graph was invalid.
func _submit_refusal(answer: Variant) -> String:
    if not (answer is Dictionary):
        return "ComfyUI would not take the job."
    var body: Dictionary = answer
    var node_errors: Dictionary = body.get("node_errors", {})
    for node_id in node_errors:
        var errors: Array = (node_errors[node_id] as Dictionary).get("errors", [])
        if not errors.is_empty():
            return "ComfyUI would not take the job: %s" % String(
                    (errors[0] as Dictionary).get("message", "one of the nodes was wrong"))
    var outer: Dictionary = body.get("error", {})
    var message := String(outer.get("message", ""))
    if message.is_empty():
        return "ComfyUI would not take the job."
    return "ComfyUI would not take the job: %s" % message


# --- Bookkeeping ---------------------------------------------------------

## Names this dock to the server, so a shared server only pushes our own events at us.
##
## Worked out from the node's own identity, which is unique for as long as it exists and
## costs nothing to ask for.
func _client_id() -> String:
    return "image-wrangler-%d" % get_instance_id()


## Whether [param run] has been overtaken, so its reply should be dropped.
func _stale(run: int) -> bool:
    return _shutting_down or run != _run_id


func _set_state(state: int) -> void:
    if _state == state:
        return
    _state = state
    state_changed.emit(state)


## Ends a run badly: back to ready, and one sentence saying why.
func _end_run(reason: String) -> void:
    _set_state(State.READY if _state == State.RUNNING else _state)
    failed.emit(reason)
