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
const DEFAULT_PORT := 8188

## How long a start may take before it is given up on, and how often it is asked. The first
## start of the day loads the whole of PyTorch.
const START_TIMEOUT := 180.0
const START_POLL_SECONDS := 1.0

## How long each kind of request may take. Fetching a picture is slower than asking a
## question, and a picture can be a few megabytes over loopback.
const ASK_TIMEOUT := 10.0
const FETCH_TIMEOUT := 60.0

## What separates the parts of an upload. Anything the file itself cannot contain will do.
const UPLOAD_BOUNDARY := "ImageWranglerUpload"

## How often the run is asked whether it has finished.
const POLL_SECONDS := 1.0

## How often the dock looks to see whether the server is still there. See [method heartbeat].
const HEARTBEAT_SECONDS := 10.0

## How many polls in a row may fail before the run is called lost.
##
## More than one, deliberately. A single dropped request over loopback while the graphics
## card is pinned is ordinary, and calling that a crash would be wrong far more often than
## it was right.
const POLL_FAILURES_ALLOWED := 3

## How long a run may go without a sign of life before it is let go, in seconds.
const STALL_SECONDS := 180.0

enum State { OFFLINE, STARTING, READY, RUNNING }

## Emitted when the server comes or goes, or a run starts or stops. See [enum State].
signal state_changed(state: int)

## Emitted once the server has said what models and samplers it has. Carries
## [code]checkpoints[/code], [code]loras[/code], [code]samplers[/code] and
## [code]schedulers[/code], each an Array of names.
signal info_ready(lists: Dictionary)

## Emitted as a run goes along. [param fraction] is -1.0 when there is nothing to measure,
## which is most of a run until the pictures start coming back.
signal progress(fraction: float, note: String)

## Emitted as each picture arrives, before the rest of the batch is made. [param index]
## counts from zero.
signal image_ready(image: Image, index: int, total: int)

## Emitted when a whole batch finishes, with one [Image] per picture made.
signal finished(images: Array)

## Emitted when a run could not be made or could not be finished. [param reason] is one
## sentence fit for a status line.
signal failed(reason: String)

## Emitted when a run was stopped on purpose.
##
## Its own signal rather than a [signal failed] with a polite reason, because nothing went
## wrong and the tab should not say anything did.
signal cancelled()

## Whether a server this dock started is killed on the way out.
##
## Off leaves it up between editor sessions, which saves the PyTorch load next time.
var stop_on_exit := true

var _url := DEFAULT_URL
var _state := State.OFFLINE

## The process this dock started, or -1. See [method owns_process].
##
## Never written to disk to be picked up again later: the OS reuses process ids, and a
## stored one would eventually name something else entirely.
var _owned_pid := -1

## Bumped for every run. Every reply carries the number it was asked under, so an answer
## belonging to a run that has already been abandoned is dropped rather than acted on.
var _run_id := 0

## Set on the way out so a reply arriving after the dock has gone does nothing.
var _shutting_down := false

## What the server last said it has. Kept so a second tab visit does not re-ask.
var _lists := {}

## The job in flight, so it can be taken back out of the queue. Empty between runs.
var _prompt_id := ""

## Which picture of the batch is being made, and how many there are. Used to work the
## progress bar and its caption across the whole batch rather than one picture at a time.
var _batch_index := 0
var _batch_total := 1

## The socket the server pushes progress down, open only while a run is in flight.
##
## [b]A progress bar and nothing else.[/b] Nothing here decides that a run finished — if it
## drops, the bar stops moving and the poll carries the run to its end exactly as before.
var _socket: WebSocketPeer

## When something last happened, for the watchdog. Any frame off the socket counts, since
## the server only sends one while it is working.
var _last_life_msec := 0

## Set while a heartbeat is in the air, so a slow answer cannot be overlapped by the next
## tick of the timer. See [method heartbeat].
var _heartbeat_busy := false


func _exit_tree() -> void:
    shut_down()


## Pumps the socket. On only while one is open, which is only while a run is in flight.
func _process(_delta: float) -> void:
    if _socket == null:
        set_process(false)
        return
    _socket.poll()
    var ready := _socket.get_ready_state()
    if ready == WebSocketPeer.STATE_CLOSING:
        return
    if ready == WebSocketPeer.STATE_CLOSED:
        # Quietly. The bar stops moving and the poll finishes the run, which is the whole
        # point of not letting this decide anything.
        _close_socket()
        return
    if ready != WebSocketPeer.STATE_OPEN:
        return
    while _socket.get_available_packet_count() > 0:
        var packet := _socket.get_packet()
        # Binary frames are preview pictures, which we never asked for. was_string_packet
        # describes the packet just taken, so it has to be read after it.
        if _socket.was_string_packet():
            _read_frame(packet.get_string_from_utf8())


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


## Whether ComfyUI is a process this dock started.
##
## The only thing Stop follows. One that was already up when the dock found it is somebody
## else's, and stopping it would take away something we were only borrowing.
##
## Forgets a process that has since died, rather than only reporting it: holding the id of
## something gone is how a reused id gets the wrong thing killed.
func owns_process() -> bool:
    if _owned_pid > 0 and not OS.is_process_running(_owned_pid):
        _owned_pid = -1
    return _owned_pid > 0


## Starts ComfyUI from [param root] and waits for it to answer.
##
## [b]The first act is a probe.[/b] Something already answering is connected to and left
## unowned — a second ComfyUI would only fight for the port.
func start(root: String) -> void:
    if _shutting_down or _state != State.OFFLINE or owns_process():
        return

    var install := IWComfyInstall.resolve(root)
    if not install["found"]:
        failed.emit(install["note"])
        return

    _run_id += 1
    var run := _run_id
    _set_state(State.STARTING)
    progress.emit(-1.0, "Looking for a server already running")

    var already := await _ask(_url + "/system_stats", ASK_TIMEOUT)
    if _stale(run):
        return
    if already["ok"]:
        _set_state(State.READY)
        await _fetch_lists()
        return

    # A console of its own, which is the log tail for free. Never through cmd: the id would
    # be cmd's, and killing that orphans python on the graphics card.
    var pid := OS.create_process(String(install["python"]),
            PackedStringArray([String(install["main"]), "--port", str(_port())]), true)
    if pid <= 0:
        _set_state(State.OFFLINE)
        failed.emit("Could not start %s." % String(install["python"]).get_file())
        return
    _owned_pid = pid
    await _wait_for_start(run)


## Stops the server, but only one this dock started. See [method owns_process].
func stop() -> void:
    if not owns_process():
        return
    _run_id += 1
    _close_socket()
    OS.kill(_owned_pid)
    _owned_pid = -1
    _lists = {}
    _prompt_id = ""
    _set_state(State.OFFLINE)


## Polls until the server answers, or gives up on it.
func _wait_for_start(run: int) -> void:
    progress.emit(-1.0, "Starting ComfyUI. The first start loads the whole of PyTorch, so give it a minute.")
    var waited := 0.0
    while waited < START_TIMEOUT:
        await get_tree().create_timer(START_POLL_SECONDS).timeout
        if _stale(run):
            return
        waited += START_POLL_SECONDS

        # Gone before it ever answered. Why is in the console it opened, which is still on
        # screen because it was started with one.
        if not OS.is_process_running(_owned_pid):
            _owned_pid = -1
            _set_state(State.OFFLINE)
            failed.emit("ComfyUI stopped before it was ready. Its console window says why.")
            return

        var reply := await _ask(_url + "/system_stats", ASK_TIMEOUT)
        if _stale(run):
            return
        if reply["ok"]:
            _set_state(State.READY)
            await _fetch_lists()
            return

    # The process is left alone and still owned: slow is not dead, and Stop is the way out.
    _set_state(State.OFFLINE)
    failed.emit("ComfyUI has not answered in %d minutes. It may still be loading — press Connect."
            % int(START_TIMEOUT / 60.0))


## The port out of the address, so the server cannot come up somewhere the dock is not
## looking.
func _port() -> int:
    var host := _url.get_slice("/", 2)
    if not host.contains(":"):
        return DEFAULT_PORT
    return maxi(host.get_slice(":", 1).to_int(), 1)


## Looks to see whether the server is still where it was, quietly.
##
## [b]Only the two changes are reported: it came back, or it went.[/b] Still missing is not
## news, and this runs on a timer.
##
## Left alone while a run or a start is in flight, since both already poll.
func heartbeat() -> void:
    if _shutting_down or _busy_state() or _heartbeat_busy:
        return
    _heartbeat_busy = true
    var before := _state
    var reply := await _ask(_url + "/system_stats", ASK_TIMEOUT)
    _heartbeat_busy = false
    # Anything that moved while the question was in the air knows more than this does.
    if _shutting_down or _busy_state() or _state != before:
        return

    var alive: bool = reply["ok"] and reply["json"] is Dictionary \
            and (reply["json"] as Dictionary).has("system")
    if alive and before == State.OFFLINE:
        _set_state(State.READY)
        if _lists.is_empty():
            await _fetch_lists()
        return
    if not alive and before == State.READY:
        _lists = {}
        _set_state(State.OFFLINE)
        failed.emit("Lost ComfyUI. It may have closed — check its console.")


## Whether something with a poll of its own is already in charge.
func _busy_state() -> bool:
    return _state == State.RUNNING or _state == State.STARTING


## Asks whether the server is there, and what it has.
##
## Safe to call on every visit to the tab. A server already known and answering is not
## asked for its lists again — only a reconnection is.
func probe() -> void:
    if _shutting_down or _state == State.RUNNING or _state == State.STARTING:
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


## Where a picture this dock sends lands in the server's input folder.
##
## One name, overwritten every run, so a session leaves no pile of copies. The client id is
## in it so two docks on one server cannot tread on each other.
func source_filename() -> String:
    return "%s_source.png" % _client_id()


## Sends one graph and follows it to its end. See [method submit_batch].
func submit(graph: Dictionary, source: Image = null) -> void:
    await submit_batch([graph], source)


## Sends each graph in turn, one whole picture at a time.
##
## [param source] is the picture the runs start from, or null for runs from noise. It goes
## up once, under [method source_filename] — the name the graphs must already be using.
##
## [b]One graph at a time rather than one job of many.[/b] It is what lets each picture be
## handed over the moment it is made, and what lets each carry its own seed.
##
## One batch at a time. A second press while one is going is refused rather than queued: a
## generation costs a minute of graphics card, and nobody asks for two by accident.
func submit_batch(graphs: Array, source: Image = null) -> void:
    if _shutting_down or _state == State.RUNNING or graphs.is_empty():
        return
    if _state == State.OFFLINE:
        failed.emit("Not connected to ComfyUI.")
        return

    _run_id += 1
    var run := _run_id
    _prompt_id = ""
    _batch_index = 0
    _batch_total = graphs.size()
    _last_life_msec = Time.get_ticks_msec()
    _set_state(State.RUNNING)

    if source != null:
        progress.emit(-1.0, "Sending the picture")
        var upload_trouble := await _upload_source(source)
        if _stale(run):
            return
        if not upload_trouble.is_empty():
            _end_run(upload_trouble)
            return

    # Opened before the first job is sent rather than after, so the frames for its first
    # steps are not lost to a handshake. Held open for the whole batch.
    _open_socket()

    var made: Array[Image] = []
    for i in graphs.size():
        _batch_index = i
        progress.emit(_overall(0.0), "%sSending the job" % _batch_prefix())
        var images: Variant = await _run_one(graphs[i], run)
        if images == null:
            # Already reported, or overtaken. Either way the batch is over.
            return
        for image: Image in images:
            made.append(image)
            image_ready.emit(image, made.size() - 1, _batch_total)

    if made.is_empty():
        _end_run("The batch finished but made no pictures.")
        return

    _prompt_id = ""
    _close_socket()
    _set_state(State.READY)
    finished.emit(made)


## One graph, start to finish. Null when it could not be finished, with the reason already
## reported — the batch stops there rather than carrying on into the same wall.
func _run_one(graph: Dictionary, run: int) -> Variant:
    var body := JSON.stringify({"prompt": graph, "client_id": _client_id()})
    var reply := await _send(_url + "/prompt", body, ASK_TIMEOUT)
    if _stale(run):
        return null
    if not reply["ok"]:
        _end_run("Could not send the job. %s" % reply["note"])
        return null

    var answer: Variant = reply["json"]
    if not (answer is Dictionary) or not (answer as Dictionary).has("prompt_id"):
        _end_run(_submit_refusal(answer))
        return null

    _prompt_id = String((answer as Dictionary)["prompt_id"])
    return await _follow(_prompt_id, run)


## Where a fraction of the picture being made sits across the whole batch.
func _overall(within: float) -> float:
    if _batch_total <= 1:
        return within
    return clampf((float(_batch_index) + within) / float(_batch_total), 0.0, 1.0)


## Names which picture is being made, or empty when there is only one.
func _batch_prefix() -> String:
    if _batch_total <= 1:
        return ""
    return "Picture %d of %d — " % [_batch_index + 1, _batch_total]


## Stops the run in flight, at the server as well as here.
##
## Both routes are taken, because a job may be running or may still be waiting behind
## another: interrupt reaches the first, taking it out of the queue reaches the second, and
## neither reaches both. Neither answer is waited on — the run is over here the moment the
## number is bumped, and a reply saying so would arrive after the fact.
func cancel() -> void:
    if _state != State.RUNNING:
        return
    var prompt_id := _prompt_id
    # First, so the run drops out at its next checkpoint rather than reporting into a tab
    # that has already been told it stopped.
    _run_id += 1
    _prompt_id = ""
    _close_socket()
    _set_state(State.READY)
    cancelled.emit()

    _send(_url + "/interrupt", "", ASK_TIMEOUT)
    if not prompt_id.is_empty():
        _send(_url + "/queue", JSON.stringify({"delete": [prompt_id]}), ASK_TIMEOUT)


## Drops whatever is in flight on the way out.
##
## A run is deliberately left alone: the reply would arrive after the dock has gone, and the
## picture is written to ComfyUI's own output folder whether we are here to collect it or
## not. The process itself goes only if we started it and were asked to take it with us.
func shut_down() -> void:
    _shutting_down = true
    _run_id += 1
    _close_socket()
    if stop_on_exit and owns_process():
        OS.kill(_owned_pid)
    _owned_pid = -1


# --- The progress socket -------------------------------------------------

## Opens the socket the server pushes progress down.
##
## Failing to open is not worth reporting. It costs the step-by-step bar and nothing else,
## and saying so would be an error message about a run that is going perfectly well.
func _open_socket() -> void:
    _close_socket()
    if _shutting_down:
        return
    var socket := WebSocketPeer.new()
    if socket.connect_to_url(_socket_url()) != OK:
        return
    _socket = socket
    set_process(true)


func _close_socket() -> void:
    if _socket != null:
        _socket.close()
        _socket = null
    set_process(false)


## The socket's address, worked out from the one the user typed.
##
## [code]https[/code] is not caught by the first replacement — after [code]http[/code] comes
## an [code]s[/code] rather than a colon — so the two cannot both fire.
func _socket_url() -> String:
    var base := _url.replace("http://", "ws://").replace("https://", "wss://")
    return "%s/ws?clientId=%s" % [base, _client_id().uri_encode()]


## One frame off the socket.
##
## Only two kinds are used. Everything else is dropped, including the errors — those are
## read off [code]/history[/code] instead, where they arrive whether the socket was up or
## not.
func _read_frame(text: String) -> void:
    var json := JSON.new()
    if json.parse(text) != OK or not (json.data is Dictionary):
        return
    var frame: Dictionary = json.data
    if not (frame.get("data") is Dictionary):
        return
    var data: Dictionary = frame["data"]

    # Anything at all is the server saying it is still working. See the watchdog in _follow.
    _last_life_msec = Time.get_ticks_msec()

    match String(frame.get("type", "")):
        "progress":
            var total := float(data.get("max", 0.0))
            if total <= 0.0:
                return
            var value := float(data.get("value", 0.0))
            progress.emit(_overall(clampf(value / total, 0.0, 1.0)),
                    "%sStep %d of %d" % [_batch_prefix(), int(value), int(total)])
        "executing":
            # A node of null is the graph reaching its end. Nothing is confirmed by it —
            # the picture is still fetched off /history, which is what actually says the run
            # is done and what it made.
            #
            # Reported as unmeasurable so only the words change: the steps have already
            # walked the bar to its end, and claiming a number here would be a second
            # opinion about the same thing.
            if data.get("node") == null:
                progress.emit(-1.0, "Finishing")


# --- Following a run -----------------------------------------------------

## Polls until the job is done, then fetches what it made.
##
## [b]The poll is what carries the run, whether or not the socket is up.[/b] All the socket
## does is move the bar and keep the watchdog quiet.
func _follow(prompt_id: String, run: int) -> Variant:
    progress.emit(_overall(0.0), "%sGenerating" % _batch_prefix())
    var misses := 0

    while true:
        await get_tree().create_timer(POLL_SECONDS).timeout
        if _stale(run):
            return null

        var reply := await _ask("%s/history/%s" % [_url, prompt_id], ASK_TIMEOUT)
        if _stale(run):
            return null

        if not reply["ok"]:
            misses += 1
            if misses >= POLL_FAILURES_ALLOWED:
                _end_run("ComfyUI stopped answering. It may have run out of memory and closed — check its console.")
                return null
            continue
        misses = 0

        var history: Variant = reply["json"]
        if not (history is Dictionary) or not (history as Dictionary).has(prompt_id):
            # Still queued or still working. Nothing is wrong with an empty answer, so the
            # only thing that ends the wait is the job going quiet for a long time.
            #
            # Measured from the last frame off the socket rather than from the start, so a
            # long run that is plainly working is never cut off. A job waiting behind
            # somebody else's is quiet too — which is why this is minutes, and why it says
            # the run was let go rather than that anything failed.
            if Time.get_ticks_msec() - _last_life_msec >= int(STALL_SECONDS * 1000.0):
                _end_run("ComfyUI has said nothing for %d minutes. The run was let go — it may still be going, so check its console."
                        % int(STALL_SECONDS / 60.0))
                return null
            continue

        var entry: Dictionary = (history as Dictionary)[prompt_id]
        var trouble := _run_trouble(entry)
        if not trouble.is_empty():
            _end_run(trouble)
            return null
        var outputs: Dictionary = entry.get("outputs", {})
        if outputs.is_empty():
            continue
        return await _collect(outputs, run)
    # Never reached. The loop above only ends by returning, but the compiler cannot see it.
    return null


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


## Fetches every picture one graph made, or null when it could not be finished.
func _collect(outputs: Dictionary, run: int) -> Variant:
    var wanted := []
    for node_id in outputs:
        for entry in (outputs[node_id] as Dictionary).get("images", []):
            # Temp pictures belong to a preview node somebody else queued.
            if String((entry as Dictionary).get("type", "output")) != "output":
                continue
            wanted.append(entry)

    if wanted.is_empty():
        _end_run("The run finished but made no pictures.")
        return null

    var images: Array[Image] = []
    var lost := 0
    for i in wanted.size():
        progress.emit(_overall(float(i) / float(wanted.size())),
                "%sFetching %d of %d" % [_batch_prefix(), i + 1, wanted.size()])
        var image := await _fetch_image(wanted[i])
        if _stale(run):
            return null
        if image == null:
            lost += 1
            continue
        images.append(image)

    if images.is_empty():
        _end_run("ComfyUI made the picture but would not hand it over.")
        return null

    _prompt_id = ""
    # Said rather than failed: some of it came down, and the rest of the batch is still to
    # make. A failure here would stop everything over a picture that is already in hand.
    if lost > 0:
        progress.emit(-1.0, "Got %d of %d pictures; the rest would not come down."
                % [images.size(), wanted.size()])
    return images


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


# --- Sending a picture ---------------------------------------------------

## Puts [param image] in the server's input folder. Returns why it could not, or empty.
func _upload_source(image: Image) -> String:
    var png := image.save_png_to_buffer()
    if png.is_empty():
        return "Could not encode the picture to send."
    var headers := PackedStringArray([
        "Content-Type: multipart/form-data; boundary=%s" % UPLOAD_BOUNDARY])
    # The picture timeout, since this is megabytes going the other way.
    var reply := await _request(_url + "/upload/image", FETCH_TIMEOUT,
            HTTPClient.METHOD_POST, _upload_body(png, source_filename()), headers, false)
    if not reply["ok"]:
        return "Could not send the picture. %s" % reply["note"]
    return ""


## The upload's body: the file, then the flag that lets it land on last run's copy.
static func _upload_body(png: PackedByteArray, filename: String) -> PackedByteArray:
    var head := "--%s\r\nContent-Disposition: form-data; name=\"image\"; filename=\"%s\"\r\nContent-Type: image/png\r\n\r\n" % [UPLOAD_BOUNDARY, filename]
    var tail := "\r\n--%s\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\ntrue\r\n--%s--\r\n" % [UPLOAD_BOUNDARY, UPLOAD_BOUNDARY]
    var body := head.to_utf8_buffer()
    body.append_array(png)
    body.append_array(tail.to_utf8_buffer())
    return body


# --- Requests ------------------------------------------------------------

## Named [code]_ask[/code] rather than the obvious thing: [code]_get[/code] is [Object]'s
## own property hook, and overriding it with another signature will not compile.
func _ask(url: String, timeout: float, want_bytes := false) -> Dictionary:
    return await _request(url, timeout, HTTPClient.METHOD_GET, PackedByteArray(),
            PackedStringArray(), want_bytes)


func _send(url: String, body: String, timeout: float) -> Dictionary:
    var headers := PackedStringArray()
    if not body.is_empty():
        headers.append("Content-Type: application/json")
    return await _request(url, timeout, HTTPClient.METHOD_POST, body.to_utf8_buffer(),
            headers, false)


## One request, made and thrown away. Returns [code]ok[/code], [code]code[/code],
## [code]json[/code], [code]body[/code] and a [code]note[/code] fit for a status line.
##
## The body is bytes rather than text, because an upload is a PNG.
##
## A node each rather than one reused: an [HTTPRequest] carries one request at a time, and
## a probe landing on the same node as a run in flight would take the run's reply. These
## are paced by the user rather than by the frame, so a node per call costs nothing worth
## saving.
func _request(url: String, timeout: float, method: int, body: PackedByteArray,
        headers: PackedStringArray, want_bytes: bool) -> Dictionary:
    if _shutting_down or not is_inside_tree():
        return {"ok": false, "code": 0, "json": null, "body": PackedByteArray(),
                "note": "The dock is closing."}

    var http := HTTPRequest.new()
    http.timeout = timeout
    # Keeps a slow reply off the main thread. The completion still arrives on it.
    http.use_threads = true
    add_child(http)

    var error := http.request_raw(url, headers, method, body)
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
    _prompt_id = ""
    _close_socket()
    _set_state(State.READY if _state == State.RUNNING else _state)
    failed.emit(reason)
