# mfdc-topic-classifier

Trainable, versioned topic classifier for call transcripts (MFDC / TelBI). Human-in-the-loop:

1. Admin creates topics (`broker.call_topics`).
2. Supervisors label real calls by topic in the UI (`broker.call_topic_labels`) — the growing dataset.
3. **Training** (weekly, scheduled by mfdc-runner → `POST /train`): the frozen embedding model
   (`intfloat/multilingual-e5-base` by default, MIT) turns each labeled transcript into a vector; a **logistic
   regression head** is trained on those vectors, **exported to ONNX** (skl2onnx) and stored as a new
   **version** in `broker.call_topic_models` (one active row per domain).
4. **Inference** (`POST /classify`): the active ONNX model for the domain is loaded and run via
   **onnxruntime** on the transcript embedding; topics with probability ≥ `MIN_PROB` are returned.
5. Supervisors keep labeling → each retrain yields a new, more accurate version. Lineage is kept.

The embedding model is a **frozen feature extractor** — it is not fine-tuned per company (that needs a
GPU and thousands of labels). The trainable/versioned ONNX artifact is the lightweight classifier head,
which is exactly what improves as the labeled dataset grows.

## API
- `GET  /healthz` → `{status, model, device, domains:{<domain_id>:<version>}}`
- `POST /train` → retrain heads from labels, export ONNX, store new versions → `{ok, trained_domains}`
- `POST /reindex` → reload active models + topic names from DB (no retrain; after topic CRUD) → `{ok, domains}`
- `POST /classify` `{ "text": "...", "domain_id": 1, "top_k": 3 }` →
  `{ "topics": [ {"id":1,"name":"Возврат","score":0.91}, ... ] }`

## Run
```bash
cd deploy/topic-classifier
# set PG_DSN in docker-compose.yml (same PostgreSQL MFDC uses)
docker compose up -d --build
curl -s http://127.0.0.1:9601/healthz
curl -s -XPOST http://127.0.0.1:9601/train      # after supervisors have labeled some calls
```

## Notes
- Training needs **≥ 2 topics** with labels in a domain (a multiclass head needs ≥2 classes). Before that,
  `/classify` returns no topics. Seed example phrases on a topic (optional, in the UI) count as labels and
  help bootstrap. Add more labeled calls per topic to improve accuracy, then the weekly `/train` picks them up.
- Licences: e5 (MIT), sentence-transformers (Apache-2.0), scikit-learn (BSD), skl2onnx (Apache-2.0),
  onnxruntime (MIT) — commercial use OK. Default embedder: **`multilingual-e5-base`** (faster than large).
- After switching embedder, run **`POST /train`** — existing ONNX heads are incompatible.
- `POST /classify/batch` — mfdc-runner sends up to 20 transcripts per request (batched embedding).
- `MIN_PROB` (env, default 0.30) is the min class probability to assign a topic. The per-topic `threshold`
  field on a topic is legacy (from the earlier cosine approach) and is not used by the ONNX classifier.
- Single instance assumed (it trains + serves). Model weights cached in the `topic-cache` volume.
- Served by **gunicorn** + `UvicornWorker` (1 worker — shared embedder/ONNX in RAM). `/train` may run
  several minutes; gunicorn timeout is 600s.
