# mfdc-whisper

Post-call transcription sidecar for MFDC (TelBI). A small FastAPI service around **faster-whisper**:
it takes a **stereo** recording (left = caller, right = operator), splits the two channels with ffmpeg,
transcribes each independently, and merges the segments by start time into one ordered dialogue with
per-side speaker labels.

**Why stereo + per-channel:** each side is a clean mono stream, so speaker attribution is exact (no ML
diarization) and overlapping speech doesn't garble the text. Turn order is recovered from Whisper's
segment timestamps. MFDC records stereo already (`RECORD_STEREO=true`, see
`shared/function/recordings.go` and the campaign leg in `inbound_queue_fs.go`).

**Licence:** faster-whisper (MIT), CTranslate2 (MIT), Whisper weights (MIT) — commercial use allowed.

## Run
```bash
cd deploy/whisper
docker compose up -d --build
curl -s http://127.0.0.1:9600/healthz
# transcribe a stereo file:
curl -s -F file=@call.mp3 -F language=ru http://127.0.0.1:9600/transcribe | jq
```

## API
- `GET  /healthz` → `{status, model, device}`
- `POST /transcribe` (multipart) — `file` (stereo mp3/wav), `language` (`ru`/`auto`/…), `split_channels`
  (`true`/`false`). Returns:
  ```json
  { "language":"ru", "model":"medium", "duration_sec":42.1,
    "segments":[ {"speaker":"caller","start":0.0,"end":2.4,"text":"…"}, … ],
    "text":"caller: …\noperator: …" }
  ```
  If the file is not stereo, it falls back to a single mono pass (all segments labelled as the caller).

## Deployment notes
- Same host as the other services in a standalone install. Load is controlled by the **night window**
  in the UI (System → Settings → Transcription) — mfdc-runner only sends files during that window and
  one at a time. The compose CPU/memory limits are a safety cap.
- CPU by default. For GPU: nvidia/cuda base image, `WHISPER_DEVICE=cuda`, `WHISPER_COMPUTE=float16`,
  nvidia container runtime.
- Default model: **`medium`** + `int8`. Tune `WHISPER_CPU_THREADS` / `WHISPER_NUM_WORKERS` (default 4/2).
- `WHISPER_LANG=auto` — per-channel language detection; stored in `broker.call_transcripts.language`.
- Stereo L/R merged by timestamp into chronological segments (no same-speaker merge — the UI builds a timeline with overlap slots). Long pauses (≥1s, `WHISPER_PAUSE_SPLIT`) split a monologue before merge so turn order interleaves correctly.
- The endpoint URL is configured in the UI; keep the port bound to localhost if runner is co-located,
  or expose it on the LAN if you later move Whisper to a dedicated host.
- Model weights are cached in the `whisper-cache` volume so they aren't re-downloaded on restart.
