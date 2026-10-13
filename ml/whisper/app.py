"""
mfdc-whisper — post-call transcription sidecar for MFDC (TelBI).

Accepts a stereo recording (left = caller, right = operator by convention), splits the two channels
with ffmpeg, transcribes each independently with faster-whisper (so speaker attribution is perfect and
there is no cross-talk), then merges the two segment lists by start time into a single ordered dialogue.

Licence note: faster-whisper (MIT), CTranslate2 (MIT) and the OpenAI Whisper weights (MIT) all permit
commercial use, including paid transcription.

Env:
  WHISPER_MODEL    faster-whisper model id/size (default: medium)
  WHISPER_DEVICE   cpu | cuda                      (default: cpu)
  WHISPER_COMPUTE  int8 | int8_float16 | float16   (default: int8)
  WHISPER_LANG     default language when request omits it (default: ru; use "auto" to detect)
  WHISPER_BEAM     beam size                        (default: 1)
  WHISPER_CPU_THREADS  CTranslate2 intra threads      (default: 4)
  WHISPER_NUM_WORKERS  parallel transcribe() calls (WhisperModel ctor, not transcribe arg)  (default: 2)
  WHISPER_PAUSE_SPLIT  split a speaker turn on silence gaps >= N sec (default: 1.0)
  LEFT_SPEAKER     role label for the left channel  (default: caller)
  RIGHT_SPEAKER    role label for the right channel (default: operator)
"""
import os
import subprocess
import tempfile

from fastapi import FastAPI, File, Form, UploadFile
from fastapi.responses import JSONResponse
from faster_whisper import WhisperModel

MODEL_NAME = os.getenv("WHISPER_MODEL", "medium")
DEVICE = os.getenv("WHISPER_DEVICE", "cpu")
COMPUTE = os.getenv("WHISPER_COMPUTE", "int8")
DEFAULT_LANG = os.getenv("WHISPER_LANG", "auto")
BEAM = int(os.getenv("WHISPER_BEAM", "1"))
CPU_THREADS = int(os.getenv("WHISPER_CPU_THREADS", "4"))
NUM_WORKERS = int(os.getenv("WHISPER_NUM_WORKERS", "2"))
PAUSE_SPLIT_SEC = float(os.getenv("WHISPER_PAUSE_SPLIT", "1.0"))
LEFT_SPEAKER = os.getenv("LEFT_SPEAKER", "caller")
RIGHT_SPEAKER = os.getenv("RIGHT_SPEAKER", "operator")

app = FastAPI(title="mfdc-whisper")
_model = None


def model() -> WhisperModel:
    # Lazy-load so the container starts (and /healthz answers) before the model is resident.
    global _model
    if _model is None:
        _model = WhisperModel(
            MODEL_NAME, device=DEVICE, compute_type=COMPUTE,
            cpu_threads=CPU_THREADS, num_workers=NUM_WORKERS,
        )
    return _model


def _merge_detected_lang(l_info, r_info, fallback: str) -> str:
    """Merge per-channel language detection (stereo) into one code for storage/UI."""
    langs = []
    for info in (l_info, r_info):
        if info is None:
            continue
        lang = getattr(info, "language", None)
        if lang and lang not in langs:
            langs.append(lang)
    if not langs:
        return fallback if fallback and fallback != "auto" else "unknown"
    return "+".join(langs) if len(langs) > 1 else langs[0]


def _split_channels(src: str, left: str, right: str) -> bool:
    """Split a stereo file into two mono WAVs. Returns False if the file is not stereo."""
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "a:0",
         "-show_entries", "stream=channels", "-of", "csv=p=0", src],
        capture_output=True, text=True,
    )
    # ffprobe -of csv=p=0 can emit a trailing separator (e.g. "2,") depending on the build, so parse the first
    # integer field instead of matching the whole string. Matching "2" exactly made a real stereo file report
    # "2," → not stereo → mono fallback → every segment labelled with LEFT_SPEAKER (all "caller").
    raw = (probe.stdout or "").strip()
    try:
        n_channels = int(raw.split(",")[0].strip())
    except ValueError:
        n_channels = 0
    if n_channels != 2:
        return False
    subprocess.run(
        ["ffmpeg", "-y", "-i", src, "-filter_complex",
         "[0:a]channelsplit=channel_layout=stereo[l][r]",
         "-map", "[l]", "-ar", "16000", left,
         "-map", "[r]", "-ar", "16000", right],
        check=True, capture_output=True,
    )
    return True


def _to_mono(src: str, dst: str) -> None:
    subprocess.run(
        ["ffmpeg", "-y", "-i", src, "-ac", "1", "-ar", "16000", dst],
        check=True, capture_output=True,
    )


def _append_segment(out: list, speaker: str, text: str, start: float, end: float) -> None:
    text = (text or "").strip()
    if text:
        out.append({"speaker": speaker, "start": round(start, 3), "end": round(end, 3), "text": text})


def _join_words(buf: list) -> str:
    parts = [(w or "").strip() for w in buf if (w or "").strip()]
    return " ".join(parts)


def _words_to_segments(words, speaker: str) -> list:
    """Split one channel into chunks by punctuation and long pauses (better turn order after L/R merge)."""
    out = []
    buf, cstart, cend, prev_end = [], None, None, None
    for w in words:
        word = w.word or ""
        if cstart is None:
            cstart = w.start
        if prev_end is not None and buf and (w.start - prev_end) >= PAUSE_SPLIT_SEC:
            _append_segment(out, speaker, _join_words(buf), cstart, cend)
            buf, cstart, cend = [], None, None
            cstart = w.start
        cend = w.end
        prev_end = w.end
        buf.append(word)
        if (word or "").strip().endswith((".", "?", "!", "…")):
            _append_segment(out, speaker, _join_words(buf), cstart, cend)
            buf, cstart, cend, prev_end = [], None, None, None
    if buf:
        _append_segment(out, speaker, _join_words(buf), cstart, cend)
    return out


def _sort_segments(segments: list) -> list:
    """Chronological order for UI timeline (start, then end). No same-speaker merge — UI groups overlaps."""
    return sorted(segments, key=lambda s: (s["start"], s["end"]))


def _transcribe(path: str, speaker: str, language: str):
    lang = None if language == "auto" else language
    try:
        segments, info = model().transcribe(
            path, language=lang, beam_size=BEAM, vad_filter=True, word_timestamps=True,
        )
        out = []
        # NOTE: `segments` is a lazy generator — faster-whisper may raise here, during iteration,
        # not at the transcribe() call, so the loop stays inside the try.
        for s in segments:
            words = getattr(s, "words", None)
            if not words:
                text = (s.text or "").strip()
                if text:
                    _append_segment(out, speaker, text, s.start, s.end)
                continue
            out.extend(_words_to_segments(words, speaker))
        return out, info
    except ValueError as exc:
        # faster-whisper 1.0.3 with vad_filter=True and language=None (auto) raises a bare
        # ValueError("max() arg is an empty sequence") from language detection when the VAD finds no
        # speech in the channel at all. That is a NORMAL channel on this platform, not an error: the
        # A-leg is recorded in stereo, so a caller who sat silent on hold music, or a near-empty leg
        # of an unanswered call, yields a completely speechless side. Answer "no segments" and let the
        # other channel (and the runner's 'empty' terminal state) do their job. Anything else re-raises.
        if "empty sequence" in str(exc):
            return [], None
        raise


@app.get("/healthz")
def healthz():
    return {"status": "ok", "model": MODEL_NAME, "device": DEVICE}


@app.post("/transcribe")
async def transcribe(
    file: UploadFile = File(...),
    language: str = Form(DEFAULT_LANG),
    split_channels: str = Form("true"),
    left_speaker: str = Form(""),
    right_speaker: str = Form(""),
):
    # Channel→role labels come from the caller (mfdc-runner) per call, because the mapping depends on call
    # direction: the recorded A-leg's own voice is on the LEFT channel, so LEFT is the external customer on an
    # inbound call but our operator on an outbound one. Fall back to the container defaults if not supplied.
    left_label = (left_speaker or "").strip() or LEFT_SPEAKER
    right_label = (right_speaker or "").strip() or RIGHT_SPEAKER
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "in")
        with open(src, "wb") as f:
            f.write(await file.read())

        segments = []
        detected_lang = language
        want_split = str(split_channels).lower() in ("1", "true", "yes")
        left = os.path.join(tmp, "left.wav")
        right = os.path.join(tmp, "right.wav")

        try:
            if want_split and _split_channels(src, left, right):
                # Sequential L/R on one model instance — CTranslate2 is not thread-safe for parallel
                # transcribe() on the same weights (parallel would require a second model in RAM).
                l_seg, l_info = _transcribe(left, left_label, language)
                r_seg, r_info = _transcribe(right, right_label, language)
                segments = _sort_segments(l_seg + r_seg)
                detected_lang = _merge_detected_lang(l_info, r_info, language)
            else:
                mono = os.path.join(tmp, "mono.wav")
                _to_mono(src, mono)
                seg, info = _transcribe(mono, left_label, language)
                segments = _sort_segments(seg)
                detected_lang = _merge_detected_lang(info, None, language)
        except subprocess.CalledProcessError as exc:
            return JSONResponse(status_code=422,
                                content={"error": "ffmpeg failed", "detail": exc.stderr.decode("utf-8", "ignore")[:500]})
        except Exception as exc:
            return JSONResponse(status_code=500,
                                content={"error": "transcription failed", "detail": str(exc)[:500]})

        full_text = "\n".join(f"{s['speaker']}: {s['text']}" for s in segments)
        duration = max((s["end"] for s in segments), default=0.0)
        return {
            "language": detected_lang,
            "model": MODEL_NAME,
            "duration_sec": round(duration, 3),
            "segments": segments,
            "text": full_text,
        }
