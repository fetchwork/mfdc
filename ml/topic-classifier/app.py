"""
mfdc-topic-classifier — trainable, versioned topic classifier for call transcripts (MFDC / TelBI).

Architecture (agreed): the multilingual embedding model (intfloat/multilingual-e5-large, MIT) is a FROZEN
feature extractor. The trainable "head" is a logistic regression over those embeddings, retrained each
cycle on the growing supervisor labels (runner.call_topic_labels), exported to ONNX (skl2onnx) and stored
versioned in the DB (runner.call_topic_models). Inference loads the active ONNX version per domain and runs
it via onnxruntime. As supervisors label more calls, each retrain produces a new, more accurate version.

Endpoints:
  POST /train    — retrain heads from labels (+ optional seed examples), export ONNX, store new versions,
                   reload into memory. Triggered weekly by mfdc-runner.
  POST /reindex  — reload active models + topic names from DB WITHOUT retraining (after topic CRUD).
  POST /classify — { text, domain_id, top_k } → { topics:[{id,name,score}] } via the active ONNX model.
  POST /classify/batch — { items:[{ cdr_id, text, domain_id, top_k? }] } → { results:[…] } (batched embed).
  GET  /healthz  — loaded models + versions.

Licence: multilingual-e5 (MIT), sentence-transformers (Apache-2.0), scikit-learn (BSD), skl2onnx (Apache-2.0),
onnxruntime (MIT), torch (BSD), psycopg2 (LGPL) — commercial use OK.

Env: PG_DSN, EMB_MODEL (default intfloat/multilingual-e5-base), EMB_DEVICE (cpu|cuda),
     MIN_PROB (min class probability to assign a topic, default 0.30),
     ORT_INTRA_THREADS / ORT_INTER_THREADS (onnxruntime thread caps, default 2/1),
     OMP_NUM_THREADS / MKL_NUM_THREADS (torch/numpy, default 2).
"""
import json
import os
import threading
from typing import Optional

import numpy as np
import onnxruntime as ort
import psycopg2
from fastapi import FastAPI
from pydantic import BaseModel, Field
from sentence_transformers import SentenceTransformer
from skl2onnx import to_onnx
from sklearn.linear_model import LogisticRegression

PG_DSN = os.getenv("PG_DSN", "")
EMB_MODEL = os.getenv("EMB_MODEL", "intfloat/multilingual-e5-base")
EMB_DEVICE = os.getenv("EMB_DEVICE", "cpu")
MIN_PROB = float(os.getenv("MIN_PROB", "0.30"))
ORT_INTRA_THREADS = int(os.getenv("ORT_INTRA_THREADS", "2"))
ORT_INTER_THREADS = int(os.getenv("ORT_INTER_THREADS", "1"))

app = FastAPI(title="mfdc-topic-classifier")
_emb = None
_lock = threading.Lock()
# _models: domain_id -> { version, sess, input_name, prob_idx, classes:[topic_id], names:{topic_id:name} }
_models: dict[int, dict] = {}


def emb_model() -> SentenceTransformer:
    global _emb
    if _emb is None:
        _emb = SentenceTransformer(EMB_MODEL, device=EMB_DEVICE)
    return _emb


def _embed(texts, prefix) -> np.ndarray:
    prepared = [f"{prefix}{t}" for t in texts]
    return emb_model().encode(prepared, normalize_embeddings=True, convert_to_numpy=True).astype(np.float32)


_db_lock = threading.Lock()
_conn = None  # ONE persistent PG connection, reused across /reindex and /train (reconnected on drop/DSN change)


def _reset_conn():
    global _conn
    if _conn is not None:
        try:
            _conn.close()
        except Exception:  # noqa: BLE001
            pass
        _conn = None


def _get_conn():
    """Return the persistent PG connection, (re)connecting only if it is absent or was dropped."""
    global _conn
    if not PG_DSN:
        raise RuntimeError("PG_DSN not set (supplied by mfdc-runner / mfdc-api on /reindex or /train)")
    if _conn is not None and getattr(_conn, "closed", 1) == 0:
        return _conn
    _conn = psycopg2.connect(PG_DSN)
    return _conn


def _with_conn(fn):
    """Run fn(conn) on the persistent connection under a lock, reconnecting once if it dropped. The container
    keeps a SINGLE PostgreSQL connection and reuses it across requests instead of opening a new client each
    time — otherwise the connect/close churn (mfdc-runner calls /reindex often) exhausts the server's
    max_connections ("FATAL: sorry, too many clients already")."""
    with _db_lock:
        for attempt in (1, 2):
            try:
                return fn(_get_conn())
            except psycopg2.OperationalError:
                _reset_conn()  # broken connection → drop and reconnect once
                if attempt == 2:
                    raise
            except Exception:
                # a failed statement leaves the session in "aborted transaction"; roll back so the SAME
                # connection stays reusable for the next call (don't leak/rebuild it).
                try:
                    if _conn is not None:
                        _conn.rollback()
                except Exception:  # noqa: BLE001
                    _reset_conn()
                raise


def _apply_dsn(dsn: Optional[str]):
    """Adopt a PG DSN supplied by mfdc-runner / mfdc-api (built from settings.conf — the single source of
    truth). Falls back to the PG_DSN env when callers don't provide one. On a DSN change the cached
    connection is dropped so the next query reconnects with the new credentials."""
    global PG_DSN
    dsn = (dsn or "").strip()
    if dsn and dsn != PG_DSN:
        PG_DSN = dsn
        with _db_lock:
            _reset_conn()


def _ensure_schema(conn):
    with conn.cursor() as cur:
        cur.execute("CREATE SCHEMA IF NOT EXISTS runner")
        cur.execute("""
            CREATE TABLE IF NOT EXISTS runner.call_topic_models (
                id bigserial PRIMARY KEY, domain_id integer NOT NULL, version integer NOT NULL,
                onnx bytea NOT NULL, classes jsonb NOT NULL DEFAULT '[]'::jsonb,
                sample_count integer NOT NULL DEFAULT 0, active boolean NOT NULL DEFAULT true,
                trained_at timestamptz NOT NULL DEFAULT now())
        """)
    conn.commit()


def _topic_names(cur) -> dict:
    cur.execute("SELECT id, domain_id, name FROM runner.call_topics WHERE enabled = true")
    out: dict[int, dict] = {}
    for tid, domain_id, name in cur.fetchall():
        out.setdefault(int(domain_id), {})[int(tid)] = name
    return out


def _session_from_blob(blob: bytes):
    opts = ort.SessionOptions()
    opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    opts.intra_op_num_threads = ORT_INTRA_THREADS
    opts.inter_op_num_threads = ORT_INTER_THREADS
    sess = ort.InferenceSession(blob, opts, providers=["CPUExecutionProvider"])
    input_name = sess.get_inputs()[0].name
    prob_idx = len(sess.get_outputs()) - 1
    for i, o in enumerate(sess.get_outputs()):
        if "prob" in o.name.lower():
            prob_idx = i
            break
    return sess, input_name, prob_idx


def load_active_models():
    """Load the active ONNX model per domain + topic names into memory (no retraining)."""
    if not PG_DSN:
        return

    def _fetch(conn):
        _ensure_schema(conn)
        with conn.cursor() as cur:
            names = _topic_names(cur)
            cur.execute("SELECT domain_id, version, onnx, classes FROM runner.call_topic_models WHERE active = true")
            rows = cur.fetchall()
        conn.rollback()  # end the read transaction, keep the connection open for reuse
        return names, rows

    names, rows = _with_conn(_fetch)
    new: dict[int, dict] = {}
    for domain_id, version, onnx_blob, classes in rows:
        try:
            sess, input_name, prob_idx = _session_from_blob(bytes(onnx_blob))
        except Exception as exc:  # noqa: BLE001
            print(f"topic-classifier: load model domain={domain_id} v{version} failed: {exc}")
            continue
        cls = classes if isinstance(classes, list) else json.loads(classes)
        new[int(domain_id)] = {
            "version": int(version), "sess": sess, "input_name": input_name, "prob_idx": prob_idx,
            "classes": [int(c) for c in cls], "names": names.get(int(domain_id), {}),
        }
    with _lock:
        _models.clear()
        _models.update(new)


def train() -> int:
    """Retrain a logistic-regression head per domain on labeled transcripts (+ seed examples), export to
    ONNX and store a new active version. Returns the number of domains (re)trained."""
    if not PG_DSN:
        return 0

    def _do_train(conn):
        _ensure_schema(conn)
        with conn.cursor() as cur:
            cur.execute("SELECT id, domain_id, name, examples FROM runner.call_topics WHERE enabled = true")
            topic_rows = cur.fetchall()
            cur.execute("""
                SELECT l.domain_id, l.topic_id, l.cdr_id, ct.full_text
                FROM runner.call_topic_labels l
                JOIN runner.call_transcripts ct ON ct.cdr_id = l.cdr_id
                WHERE ct.full_text IS NOT NULL AND length(trim(ct.full_text)) > 0
            """)
            label_rows = cur.fetchall()

        # Build per-domain training samples: (text, topic_id). Seed example phrases + labeled transcripts.
        per_domain: dict[int, dict] = {}  # domain -> {"texts":[], "y":[], "seen_cdr":set()}
        for tid, domain_id, _name, examples in topic_rows:
            if isinstance(examples, str):
                try:
                    examples = json.loads(examples)
                except ValueError:
                    examples = []
            d = per_domain.setdefault(int(domain_id), {"texts": [], "y": [], "cdr": {}})
            for ex in (examples or []):
                ex = str(ex).strip()
                if ex:
                    d["texts"].append(ex)
                    d["y"].append(int(tid))
        for domain_id, topic_id, cdr_id, full_text in label_rows:
            d = per_domain.setdefault(int(domain_id), {"texts": [], "y": [], "cdr": {}})
            d["texts"].append(str(full_text))
            d["y"].append(int(topic_id))

        trained = 0
        for domain_id, d in per_domain.items():
            y = np.asarray(d["y"])
            if len(y) < 2 or len(set(d["y"])) < 2:
                continue  # need >= 2 distinct topics with labels to train a multiclass head
            X = _embed(d["texts"], "passage: ")
            clf = LogisticRegression(max_iter=1000)
            clf.fit(X, y)
            onx = to_onnx(clf, X[:1], options={"zipmap": False})
            blob = onx.SerializeToString()
            classes = [int(c) for c in clf.classes_]
            with conn.cursor() as cur:
                cur.execute("SELECT COALESCE(MAX(version), 0) + 1 FROM runner.call_topic_models WHERE domain_id = %s", (domain_id,))
                version = cur.fetchone()[0]
                cur.execute("UPDATE runner.call_topic_models SET active = false WHERE domain_id = %s AND active", (domain_id,))
                cur.execute(
                    "INSERT INTO runner.call_topic_models (domain_id, version, onnx, classes, sample_count, active) "
                    "VALUES (%s, %s, %s, %s, %s, true)",
                    (domain_id, version, psycopg2.Binary(blob), json.dumps(classes), int(len(y))),
                )
            trained += 1
        conn.commit()
        return trained

    trained = _with_conn(_do_train)
    load_active_models()
    return trained


class ClassifyRequest(BaseModel):
    text: str
    domain_id: int = 0
    top_k: int = 3


class ClassifyBatchItem(BaseModel):
    cdr_id: int = 0
    text: str
    domain_id: int = 0
    top_k: int = 0


class ClassifyBatchRequest(BaseModel):
    items: list[ClassifyBatchItem] = Field(default_factory=list)


def _classify_embedding(m: dict, x: np.ndarray, top_k: int) -> list:
    """Run ONNX head on a single (1, dim) embedding; returns scored topic dicts."""
    outs = m["sess"].run(None, {m["input_name"]: x})
    probs = np.asarray(outs[m["prob_idx"]]).reshape(-1)
    scored = []
    for i, tid in enumerate(m["classes"]):
        if i >= len(probs):
            break
        p = float(probs[i])
        if p >= MIN_PROB:
            scored.append({"id": tid, "name": m["names"].get(tid, str(tid)), "score": round(p, 4)})
    scored.sort(key=lambda s: s["score"], reverse=True)
    k = top_k if top_k > 0 else 3
    return scored[:k]


@app.on_event("startup")
def _startup():
    try:
        load_active_models()
    except Exception as exc:  # noqa: BLE001 — start even if PG/models are not ready yet
        print(f"topic-classifier: initial load failed: {exc}")


@app.get("/healthz")
def healthz():
    with _lock:
        models = {d: m["version"] for d, m in _models.items()}
    return {"status": "ok", "model": EMB_MODEL, "device": EMB_DEVICE, "domains": models}


class DSNRequest(BaseModel):
    pg_dsn: Optional[str] = None


@app.post("/reindex")
def do_reindex(req: Optional[DSNRequest] = None):
    if req:
        _apply_dsn(req.pg_dsn)
    load_active_models()
    with _lock:
        return {"ok": True, "domains": len(_models)}


@app.post("/train")
def do_train(req: Optional[DSNRequest] = None):
    if req:
        _apply_dsn(req.pg_dsn)
    n = train()
    return {"ok": True, "trained_domains": n}


@app.post("/classify")
def classify(req: ClassifyRequest):
    out = classify_batch(ClassifyBatchRequest(items=[
        ClassifyBatchItem(text=req.text, domain_id=req.domain_id, top_k=req.top_k),
    ]))
    if not out["results"]:
        return {"topics": []}
    row = out["results"][0]
    if row.get("no_model"):
        return {"no_model": True}
    return {"topics": row.get("topics") or []}


@app.post("/classify/batch")
def classify_batch(req: ClassifyBatchRequest):
    if not req.items:
        return {"results": []}

    texts: list[str] = []
    text_idx: list[int] = []
    for i, item in enumerate(req.items):
        text = (item.text or "").strip()
        if text:
            texts.append(text)
            text_idx.append(i)

    embeddings: dict[int, np.ndarray] = {}
    if texts:
        embs = _embed(texts, "query: ")
        for j, i in enumerate(text_idx):
            embeddings[i] = embs[j]

    results = []
    for i, item in enumerate(req.items):
        text = (item.text or "").strip()
        if not text:
            results.append({"cdr_id": item.cdr_id, "topics": []})
            continue
        with _lock:
            m = _models.get(int(item.domain_id))
        if not m:
            results.append({"cdr_id": item.cdr_id, "no_model": True})
            continue
        x = embeddings[i].reshape(1, -1)
        top_k = item.top_k if item.top_k > 0 else 3
        topics = _classify_embedding(m, x, top_k)
        results.append({"cdr_id": item.cdr_id, "topics": topics})
    return {"results": results}
