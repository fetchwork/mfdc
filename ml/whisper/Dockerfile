# mfdc-whisper: faster-whisper post-call transcription sidecar.
# CPU image by default (night-batch on the shared host). For GPU, use an nvidia/cuda base +
# WHISPER_DEVICE=cuda WHISPER_COMPUTE=float16 and the nvidia container runtime.
FROM python:3.11-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg libgomp1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .

EXPOSE 9600
# Model weights are cached into /root/.cache (mount a volume in compose to persist across restarts).
CMD ["gunicorn", "app:app", "-k", "uvicorn.workers.UvicornWorker", "-b", "0.0.0.0:9600", "--timeout", "600"]
