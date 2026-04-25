import os
import io
import torch
import uvicorn
from fastapi import FastAPI, UploadFile, File, Form
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from faster_whisper import WhisperModel

app = FastAPI(title="Faster Whisper API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Configuration
# Default to "base" model, download to a persistent cache
MODEL_SIZE = os.environ.get("WHISPER_MODEL", "base")
DEVICE = "cuda" if torch.cuda.is_available() else "cpu"
COMPUTE_TYPE = "float16" if DEVICE == "cuda" else "int8"
whisper_model = None

@app.on_event("startup")
def load_model():
    global whisper_model
    print(f"Loading faster-whisper model {MODEL_SIZE} on {DEVICE} ({COMPUTE_TYPE})...")
    # Will download to HF_HOME which is persisted by the container
    whisper_model = WhisperModel(MODEL_SIZE, device=DEVICE, compute_type=COMPUTE_TYPE)
    print("Faster Whisper model loaded successfully.")

@app.post("/v1/audio/transcriptions")
async def create_transcription(
    file: UploadFile = File(...),
    # OpenAI's STT API uses the field name "model" — keep this aligned so
    # SillyTavern (and other OpenAI-compatible clients) can talk to us.
    # The value is currently informational only; we always use the model
    # loaded at startup via WHISPER_MODEL env var.
    model: str = Form(default="base"),
    language: str = Form(default=None),
):
    if whisper_model is None:
        return JSONResponse(status_code=503, content={"error": "Model not loaded yet"})

    try:
        content = await file.read()
        segments, info = whisper_model.transcribe(
            io.BytesIO(content),
            beam_size=5,
            language=language,
        )
        text = "".join([segment.text for segment in segments])
        return {"text": text.strip()}
    except Exception as e:
        return JSONResponse(status_code=500, content={"error": str(e)})

if __name__ == "__main__":
    port = int(os.environ.get("WHISPER_PORT", 5100))
    host = os.environ.get("WHISPER_HOST", "0.0.0.0")
    uvicorn.run(app, host=host, port=port)