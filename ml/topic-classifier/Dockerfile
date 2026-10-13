# mfdc-topic-classifier: embedding-based transcript topic tagging (Phase 2).
# CPU by default; embedding is a single forward pass so a GPU is optional. For GPU use an
# nvidia/cuda base + EMB_DEVICE=cuda and the nvidia container runtime.
FROM python:3.11-slim

# libgomp1 is required by torch/onnxruntime on slim images.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libgomp1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .

EXPOSE 9601
# Model weights are cached into /root/.cache (mount a volume in compose to persist across restarts).
CMD ["gunicorn", "app:app", "-k", "uvicorn.workers.UvicornWorker", "-b", "0.0.0.0:9601", "-w", "1", "--timeout", "600"]
