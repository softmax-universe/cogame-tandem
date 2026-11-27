# Tandem training

Build `Dockerfile.ordinary-player` and seat the resulting image as a normal
Coworld player. Certification seats a model beside the scripted baseline. An ordinary player uses the authenticated Sprite player socket. Each
turn, it receives a private view and constructs its own prompt and action.
The game parses its complete carry order and installs the quantized
order through the replay record. In text-action training and live play,
`drive: [0,0]` applies no drive force. Players can still twist, yield, or brace.

The default policy builds a view-based carry order. `TANDEM_ADAPTER_DIR` loads a trained adapter from
the player image with its matching local base model, PyTorch, Transformers,
and PEFT installed. The player's `PLAYER_PROMPT` remains private to its seat.

Set `TANDEM_CAPTURE_TRAINING=1` and `TANDEM_SOURCE_REVISION` to upload
accepted decisions as the standard player artifact. The game sends an
acceptance receipt for each decision and a final score frame before it writes
results. For receipt-only collection, set `TANDEM_CAPTURE_RECEIPTS=1` instead.
Supply `TANDEM_SOURCE_REVISION`, an episode-specific private
`COWORLD_PLAYER_ARTIFACT_UPLOAD_URL` (a mounted `file://` path also works),
and `COWORLD_EPISODE_ID` for the run join. Retain the ZIP before removing
the mount. Both capture modes write `decision_results.json` on the final frame.
Each turn records issued attempt IDs, available platform/provider call IDs, source,
and the SHA-256 of each submitted action (UTF-8 Python JSON with sorted keys,
ASCII escaping and compact separators). The game receipt identifies the selected
attempt and the executed order, including the fallback order on rejection.
Older turn-only receipts omit those two fields. Compare by episode, seat, turn
and attempt ID against the game's private `COGAME_SAVE_TRAJECTORY_URI` events.

For an offline comparison with the binary executed-order replay, retain
`COGAME_SAVE_REPLAY_URI` from the same run and pass the expected seed and seat:

```sh
python3 tools/join_decision_receipts.py --seed 137 --seat 0 \
  --receipt /private/run/policy_artifact_0.zip --replay /private/run/game.replay
```

The final frame binds the private receipt to the game, seed and SHA-256 of the
uncompressed binary replay. For each turn the report keeps the player ACK,
selected attempt and available call ID alongside the replay’s order source.
A verified acceptance requires that selected attempt in the receipt and an
exact match on the replay’s external order (six quantized integers, note and
say). A verified fallback requires a negative ACK, a null selection and the
matching fallback order. Missing evidence yields `unknown`; contradictory
identities or orders fail the comparison. Omit an unavailable input to inspect
the other side. Earlier player ZIPs lack the final-frame binding. A replay alone
can establish that an external order executed, but it cannot identify the
selected model call or establish that its player received an ACK.

For each episode and seat, `keyed_orders` counts replay turns and
`keyed_receipts` counts supplied ACK rows with a usable turn and seat.
The sorted `turns` array covers their union. Each row has `ack_present`,
including when a present ACK lacks the fields needed for verification.
`out_of_order_ack_turns` lists keyed ACKs whose turn is lower than a preceding
keyed ACK in the ZIP, in receipt order. These rows still join by turn. A repeated
keyed ACK turn fails the command, even if both copies agree. A gap alone does
not establish reordering. Unkeyed rows have separate counts.

Export at least two complete training seeds:

```sh
python3 players/ordinary/export.py /tmp/tandem-dataset \
  /tmp/tandem-run-14 /tmp/tandem-run-15 \
  --source-revision <game-source-sha> --source heuristic
```

The exporter splits whole seeds into train and validation, rejects deadline
and fault endings, and checks the source revision and game scores. Output
uses `tandem-carry-v1`, matching the native exporter:

```sh
nim c -d:release --path:src -o:/tmp/tandem-posttrain tools/export_posttrain.nim
/tmp/tandem-posttrain /tmp/tandem-data 10 1 default
```

The other certified variant is `sprint`. Both methods emit Metta post-training
JSONL with player-constructed prompts and complete accepted actions. Use the [post-training research package](https://github.com/softmax-universe/posttraining-research/tree/main/packages/metta-posttraining)
for current training and adapter-packaging workflows.

Ordinary export IDs include the complete capture hash. Matched wording runs may
share a scenario seed and remain in the same split; duplicate captures are rejected.

## Prompt selection and stored artifacts

The game sends episode-stable `promptVariant` and `promptSeed` settings to the
ordinary player. The player and native bridge consume the same complete v2
bank. Deploy both game and ordinary player changes together.

Accepted-decision artifacts record exact message hashes. Export rejects held-out
wording and validates each stored bank against its original text. Original v1
artifacts remain readable, including canonical artifacts without prompt metadata.
Current v2 prompts correct the score description; stored messages are never rewritten.

See [prompt diversity](../TRAINING.md) for selection, exports, and evaluation.

## Game-owned private episode capture

Set `COGAME_SAVE_TRAJECTORY_URI` on the game and provide `COWORLD_EPISODE_ID`,
`COWORLD_GAME_VERSION`, and `COWORLD_SOURCE_REVISION`. The game writes canonical
Bitworld decision JSONL separately from the public replay. It records private
observations, every received model attempt including failures and retries, exact
request/response bodies, received headers and native call IDs when available,
the selected parsed order, its quantised execution values, post-tick hashes,
and the terminal status and results. Missing HTTP responses are marked as
incomplete attempts. The ordinary player uses the game-issued seat and attempt
identity for sidecar requests and private evidence.

Registered scripted carriers have teacher origin; disconnected or unregistered
seats and engine fallbacks cannot claim it. Accepted means parser and execution
agree, not that teacher quality or sampled-model eligibility is established.
The older optional player ZIP format remains readable by its existing exporter;
it contains accepted decisions only and does not substitute for this game-owned
failure and execution evidence. Keep all private artifacts out of public replay
bundles and source control.
