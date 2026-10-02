"""Local word timestamps with mlx-whisper (Apple Silicon). Prints Whisper-style JSON chunks.

usage: transcribe_local.py audio.wav [from_seconds] [seconds] [model] [language]
Timestamps are whole-song seconds (from_seconds is added back).
"""
import json
import sys

import mlx_whisper
import numpy as np
from mlx_whisper.audio import SAMPLE_RATE, load_audio

path = sys.argv[1]
start = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0
seconds = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
model = sys.argv[4] if len(sys.argv) > 4 else "mlx-community/whisper-large-v3-turbo"
language = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] else None

audio = load_audio(path)
a = int(start * SAMPLE_RATE)
b = int((start + seconds) * SAMPLE_RATE) if seconds > 0 else len(audio)
clip = np.ascontiguousarray(audio[a:b])
result = mlx_whisper.transcribe(clip, path_or_hf_repo=model, word_timestamps=True, condition_on_previous_text=False,
                                language=language, no_speech_threshold=None, hallucination_silence_threshold=None)
chunks = [
    {"text": w["word"].strip(), "timestamp": [round(w["start"] + start, 3), round(w["end"] + start, 3)],
     "probability": round(float(w.get("probability", 0.0)), 3)}
    for seg in result.get("segments", []) for w in seg.get("words", [])
]
print(json.dumps({"text": result.get("text", "").strip(), "language": result.get("language"), "model": model, "chunks": chunks}))
