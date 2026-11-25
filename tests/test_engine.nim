## The turn loop against a fake LLM client: one PARALLEL batch per turn, the
## inter-batch floor, the deadlines, the budget guard, the endings and the
## no-show path.

import std/[json, monotimes, options, os, strutils, times]
import lib/helpers
import tandem/[decide, server]

type Window = object
  startMs, endMs: int64

var windows: seq[Window]
var callLog: seq[seq[int]]
var userLog: seq[string]      ## the composed user message per call, in order.

proc since(start: MonoTime): int64 =
  (getMonoTime() - start).inMilliseconds

proc fakeBatch(reply: string, delayMs = 0, fail = false): BatchFn =
  let origin = getMonoTime()
  result = proc (calls: seq[BatchCall], timeoutSeconds: int): seq[BatchReply]
      {.closure, gcsafe.} =
    {.gcsafe.}:
      var seats: seq[int] = @[]
      for call in calls:
        seats.add(call.seat)
        userLog.add(call.user)
      callLog.add(seats)
      let started = since(origin)
      if delayMs > 0:
        sleep(min(delayMs, timeoutSeconds * 1000))
      windows.add(Window(startMs: started, endMs: since(origin)))
    for call in calls:
      if fail:
        result.add BatchReply(seat: call.seat, error: "Timeout was reached")
      else:
        result.add BatchReply(seat: call.seat, ok: true, text: $(%*{
          "type": "decision", "turn": call.turn, "action": parseJson(reply)}))

proc newEngine(batch: BatchFn): TurnEngine =
  result = newTurnEngine(batch)
  for seat in Seat:
    result.policies[seat] = SeatPolicy(kind: pkExternal,
      label: "test-llm", connected: true)

proc applyRecords(engine: TurnEngine, sim: var SimServer) =
  for record in engine.records:
    sim.applyRecord(record)

proc bothSeatsInOneBatch() =
  windows.setLen(0)
  callLog.setLen(0)
  var sim = carryingSim(testConfig())
  let engine = newEngine(fakeBatch(
    """{"drive":[1,0],"effort":0.5,"yield":0.2,"twist":0,"brace":0.1}""",
    delayMs = 60))
  engine.turn(sim, 0, 0)
  doAssert callLog.len == 1, "the seats were queried in " & $callLog.len &
    " batches, not one"
  doAssert callLog[0].len == 2, "the batch carried " & $callLog[0].len &
    " calls"
  doAssert callLog[0][0] != callLog[0][1], "both calls were the same seat"
  # In-flight windows for the two seats are the SAME window by construction:
  # one `makeRequests` call carries both.
  doAssert windows.len == 1
  doAssert windows[0].endMs >= windows[0].startMs
  engine.applyRecords(sim)
  doAssert sim.hasOrder[0] and sim.hasOrder[1],
    "the batch did not install both orders"
  doAssert sim.activeOrder[0].source == osExternal
  report "both seats' calls go out as ONE parallel batch"

proc externalOrderUsesTheReplayRecord() =
  var sim = carryingSim(testConfig())
  let batch = proc(calls: seq[BatchCall], timeoutSeconds: int):
      seq[BatchReply] {.closure, gcsafe.} =
    discard timeoutSeconds
    for call in calls:
      result.add BatchReply(seat: call.seat, ok: true, text: $(%*{
        "type": "decision", "turn": call.turn,
        "action": {"drive": [1, 0], "effort": 0.5,
                   "yield": 0.2, "twist": 0, "brace": 0.1}
      }))
  let engine = newTurnEngine(batch)
  for seat in Seat:
    engine.policies[seat] = SeatPolicy(
      kind: pkExternal, connected: true, label: "external")
  engine.turn(sim, 0, 0)
  doAssert engine.externalAccepted == [true, true]
  engine.applyRecords(sim)
  for seat in Seat:
    doAssert sim.activeOrder[ord(seat)].source == osExternal
  report "external decisions install quantized orders through replay records"

proc interBatchFloor() =
  windows.setLen(0)
  callLog.setLen(0)
  var config = testConfig()
  config.minBatchSpacingMs = 400
  var sim = carryingSim(config)
  let engine = newEngine(fakeBatch(
    """{"drive":[1,0],"effort":0.5,"yield":0.2,"twist":0,"brace":0}""", delayMs = 5))
  let started = getMonoTime()
  engine.turn(sim, 0, 0)
  doAssert engine.failedSeat.isNone
  engine.applyRecords(sim)
  engine.turn(sim, 1, 0)
  doAssert engine.failedSeat.isNone
  engine.applyRecords(sim)
  let elapsed = (getMonoTime() - started).inMilliseconds
  doAssert elapsed >= 380,
    "two turns took " & $elapsed & " ms; the 400 ms floor was not applied"
  report "the inter-batch floor keeps consecutive batches apart"

proc retryThenPolicyFailure() =
  windows.setLen(0)
  callLog.setLen(0)
  var sim = carryingSim(testConfig())
  let engine = newEngine(fakeBatch("", fail = true))
  engine.turn(sim, 4, 0)
  doAssert callLog.len == 2,
    "a failing batch was attempted " & $callLog.len & " times, not twice"
  doAssert engine.failedSeat.isSome, "two consecutive failures must trigger policy failure"
  var fallbacks = 0
  var orders = 0
  for record in engine.records:
    let node = parseJson(record)
    case node["k"].getStr()
    of "fallback":
      inc fallbacks
      doAssert node["cause"].getStr() == "timeout",
        "a deadline was recorded as " & node["cause"].getStr()
    of "order":
      inc orders
    else: discard
  doAssert fallbacks == 4, "expected four diagnostic failure records, got " & $fallbacks
  doAssert orders == 0, "no substitute order may be emitted on policy failure"
  doAssert engine.decisions[Cobalt].attempts.len == 2
  doAssert engine.decisions[Cobalt].executedAction.kind == JNull
  engine.applyRecords(sim)
  doAssert not sim.hasOrder[0] and not sim.hasOrder[1],
    "a failed turn must not install any order"
  report "two consecutive failures end in policy failure with no substitute move"

proc perTurnBudget() =
  windows.setLen(0)
  callLog.setLen(0)
  var config = testConfig()
  config.turnBudgetMs = 900
  config.attempt1Ms = 600
  config.retryMs = 200
  var sim = carryingSim(config)
  let engine = newEngine(fakeBatch("", delayMs = 5000, fail = true))
  let started = getMonoTime()
  engine.turn(sim, 2, 0)
  let elapsed = (getMonoTime() - started).inMilliseconds
  doAssert elapsed < 4000,
    "a hung client held the turn for " & $elapsed & " ms"
  doAssert engine.failedSeat.isSome
  report "the per-turn budget bounds a hung client and fails cleanly"

proc invalidOrderFailsWithoutSubstitute() =
  var sim = carryingSim(testConfig())
  let engine = newEngine(fakeBatch("""{"drive":[0,0],"effort":0.5}"""))
  engine.turn(sim, 1, 0)
  doAssert engine.failedSeat.isSome
  doAssert not engine.externalAccepted[Cobalt]
  doAssert engine.decisions[Cobalt].attempts.len == 2
  doAssert engine.decisions[Cobalt].executedAction.kind == JNull
  for record in engine.records:
    doAssert parseJson(record)["k"].getStr() != "order"
  report "an invalid/incomplete order ends in policy failure without substitute"

proc wallClockStopIsDeadline() =
  var sim = carryingSim(testConfig())
  sim.wallClockStop()
  doAssert sim.endReason == reasonDeadline and sim.endRule == erWallClock
  report "the wall-clock stop yields deadline/wall_clock"

proc simFaultIsFault() =
  var sim = carryingSim(testConfig())
  sim.damage = -5
  sim.stepSim()
  doAssert sim.endReason == reasonFault and sim.endRule == erSimFault,
    "a tripped invariant ended " & reasonText(sim.endReason) & "/" &
      endRuleText(sim.endRule)
  report "a tripped invariant yields fault/sim_fault"

proc hostErrorIsFault() =
  var sim = carryingSim(testConfig())
  sim.hostErrorStop()
  doAssert sim.endReason == reasonFault and sim.endRule == erHostError
  report "an unexpected exception yields fault/host_error"

proc noTransportSeatFailsExplicitly() =
  var sim = carryingSim(testConfig())
  let engine = newTurnEngine(nil)
  engine.policies[Cobalt] = SeatPolicy(kind: pkExternal, connected: true, label: "model")
  engine.policies[Rust] = SeatPolicy(kind: pkScripted, baseline: "porter", connected: true)
  engine.turn(sim, 0, 0)
  doAssert engine.failedSeat == some(Cobalt)
  doAssert "no_transport" in engine.failureMessage
  for record in engine.records:
    doAssert parseJson(record)["k"].getStr() != "order"
  report "a non-scripted seat with no transport fails explicitly without porter"

proc disconnectedSeatFailsExplicitly() =
  callLog.setLen(0)
  var sim = carryingSim(testConfig())
  let engine = newEngine(fakeBatch(
    """{"drive":[0,1],"effort":0.9,"yield":0.2,"twist":0,"brace":0}"""))
  engine.policies[Cobalt].connected = false
  engine.turn(sim, 0, 0)
  doAssert engine.failedSeat == some(Cobalt)
  doAssert "disconnected" in engine.failureMessage
  doAssert callLog.len == 0
  for record in engine.records:
    doAssert parseJson(record)["k"].getStr() != "order"
  report "a disconnected non-scripted seat fails explicitly without porter"

proc damageLastTurnIsTheLastTurn() =
  ## The `damage_last_turn` the SEAT IS SENT is the damage taken since the
  ## previous turn boundary. The snapshot has to be left behind at the END of a
  ## turn: taken at the top, the subtraction inside the same call is
  ## `sim.damage - sim.damage` and the field is structurally 0 forever.
  userLog.setLen(0)
  var sim = carryingSim(testConfig())
  let engine = newEngine(fakeBatch(
    """{"drive":[1,0],"effort":0.5,"yield":0.2,"twist":0,"brace":0}"""))
  engine.turn(sim, 0, 0)
  engine.applyRecords(sim)
  doAssert userLog.len == 2
  doAssert """"damage_last_turn":0""" in userLog[0],
    "turn 0 was sent damage it had not taken"
  sim.damage = 31                      ## the 48 ticks between the two turns.
  engine.turn(sim, 1, 0)
  engine.applyRecords(sim)
  doAssert userLog.len == 4
  doAssert """"damage_last_turn":31""" in userLog[2],
    "the seat was not told what the last turn cost: " &
      userLog[2][userLog[2].find("condition") .. ^1][0 .. 200]
  sim.damage = 44
  engine.turn(sim, 2, 0)
  doAssert """"damage_last_turn":13""" in userLog[4],
    "the third turn did not measure from the second boundary"
  report "damage_last_turn measures the previous turn"

proc noShowIsDeclared() =
  let path = tempPath("player-failure.json")
  removeFile(path)
  putEnv("COGAME_PLAYER_FAILURE_URI", "file://" & path)
  declarePlayerFailure(1, "never joined")
  delEnv("COGAME_PLAYER_FAILURE_URI")
  doAssert fileExists(path), "no player-failure artifact was written"
  let node = parseJson(readFile(path))
  doAssert node["failed_policy_index"].getInt() == 1
  doAssert node["message"].getStr().len > 0
  removeFile(path)
  report "a lobby no-show is declared via COGAME_PLAYER_FAILURE_URI"

when isMainModule:
  bothSeatsInOneBatch()
  externalOrderUsesTheReplayRecord()
  interBatchFloor()
  retryThenPolicyFailure()
  perTurnBudget()
  invalidOrderFailsWithoutSubstitute()
  wallClockStopIsDeadline()
  simFaultIsFault()
  hostErrorIsFault()
  noTransportSeatFailsExplicitly()
  disconnectedSeatFailsExplicitly()
  damageLastTurnIsTheLastTurn()
  noShowIsDeclared()
  echo "test_engine: the turn loop is parallel, bounded and fails cleanly without substitutes"
