import os
import tempfile
from contextlib import asynccontextmanager

import torch
import uvicorn
from fastapi import FastAPI, UploadFile, File, Form
from fastapi.responses import JSONResponse, PlainTextResponse
from fastapi.middleware.cors import CORSMiddleware
from faster_whisper import WhisperModel

# Configuration
# Default to "base" model, downloaded into HF_HOME (persisted by the container).
MODEL_SIZE = os.environ.get("WHISPER_MODEL", "base")
DEVICE = "cuda" if torch.cuda.is_available() else "cpu"
COMPUTE_TYPE = "float16" if DEVICE == "cuda" else "int8"

# How much of an upload we'll buffer in memory before spilling to disk.
# Keep small — long voice notes through a basic WhisperModel can otherwise
# hold the whole file in RAM twice (raw bytes + decoded audio).
UPLOAD_CHUNK_BYTES = 1024 * 1024  # 1 MiB

whisper_model: WhisperModel | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Load the model on startup, release it on shutdown."""
    global whisper_model
    print(f"Loading faster-whisper model {MODEL_SIZE} on {DEVICE} ({COMPUTE_TYPE})...")
    whisper_model = WhisperModel(MODEL_SIZE, device=DEVICE, compute_type=COMPUTE_TYPE)
    print("Faster Whisper model loaded successfully.")
    yield
    whisper_model = None


app = FastAPI(title="Faster Whisper API", lifespan=lifespan)

# CORS: SillyTavern and other in-browser clients call us cross-origin.
# allow_credentials must be False when allow_origins is "*" — browsers
# silently ignore the credentials flag with a wildcard origin anyway.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
async def health():
    """Lightweight readiness probe."""
    return {"status": "ok" if whisper_model is not None else "loading"}


@app.post("/v1/audio/transcriptions")
async def create_transcription(
    file: UploadFile = File(...),
    # OpenAI's STT API uses these field names — keep them aligned so
    # SillyTavern (and other OpenAI-compatible clients) just work.
    # `model` is currently informational; we always use the model loaded
    # at startup via the WHISPER_MODEL env var.
    model: str = Form(default="base"),
    language: str = Form(default=None),
    prompt: str = Form(default=None),
    temperature: float = Form(default=0.0),
    response_format: str = Form(default="json"),
):
    if whisper_model is None:
        return JSONResponse(status_code=503, content={"error": "Model not loaded yet"})

    # Spool the upload to a temp file so we don't hold the entire audio
    # buffer in memory. faster-whisper accepts a path directly.
    suffix = os.path.splitext(file.filename or "")[1] or ".audio"
    try:
        with tempfile.NamedTemporaryFile(suffix=suffix, delete=True) as tmp:
            while True:
                chunk = await file.read(UPLOAD_CHUNK_BYTES)
                if not chunk:
                    break
                tmp.write(chunk)
            tmp.flush()

            segments, info = whisper_model.transcribe(
                tmp.name,
                beam_size=5,
                language=language,
                initial_prompt=prompt,
                temperature=temperature,
            )
            text = "".join(segment.text for segment in segments).strip()
    except Exception as e:
        return JSONResponse(status_code=500, content={"error": str(e)})

    # OpenAI's API supports several response formats. We cover the two
    # SillyTavern actually uses; everything else falls back to JSON.
    if response_format in ("text", "txt"):
        return PlainTextResponse(text)
    if response_format == "verbose_json":
        return {
            "text": text,
            "language": info.language,
            "duration": info.duration,
        }
    return {"text": text}


if __name__ == "__main__":
    port = int(os.environ.get("WHISPER_PORT", 5100))
    host = os.environ.get("WHISPER_HOST", "0.0.0.0")
    uvicorn.run(app, host=host, port=port)
