"""Local Demucs vocal separation. usage: stems_local.py audio.wav out_dir [from_seconds] [seconds] [model]

Writes out_dir/vocals.wav and out_dir/no_vocals.wav, both aligned to `from_seconds` of the source
(prefix-padded with silence so they stay full-song aligned when from_seconds > 0). Prints JSON paths.
"""
import json
import os
import sys

import numpy as np
import soundfile as sf
import torch
from demucs.apply import apply_model
from demucs.pretrained import get_model

path, out = sys.argv[1], sys.argv[2]
start = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
seconds = float(sys.argv[4]) if len(sys.argv) > 4 else 0.0
name = sys.argv[5] if len(sys.argv) > 5 else "htdemucs"

data, rate = sf.read(path, always_2d=True, dtype="float32")
a = int(start * rate)
b = int((start + seconds) * rate) if seconds > 0 else len(data)
clip = data[a:b]
if clip.shape[1] == 1:
    clip = np.repeat(clip, 2, axis=1)
model = get_model(name)
model.eval()
if rate != model.samplerate:
    raise SystemExit(f"resample to {model.samplerate} Hz first (got {rate})")
device = "mps" if torch.backends.mps.is_available() else "cpu"
wav = torch.from_numpy(clip.T.copy())
ref = wav.mean(0)
wav = (wav - ref.mean()) / (ref.std() + 1e-8)
with torch.no_grad():
    sources = apply_model(model, wav[None], device=device, split=True, overlap=0.25, progress=False)[0]
sources = sources * (ref.std() + 1e-8) + ref.mean()
vi = model.sources.index("vocals")
vocals = sources[vi].cpu().numpy().T
rest = (sources.sum(0) - sources[vi]).cpu().numpy().T
os.makedirs(out, exist_ok=True)
pad = np.zeros((a, 2), dtype=np.float32)
paths = {}
for key, sig in (("vocals", vocals), ("no_vocals", rest)):
    p = os.path.join(out, f"{key}.wav")
    sf.write(p, np.concatenate([pad, sig]), rate)
    paths[key] = p
print(json.dumps({"model": name, "device": device, "from": start, **paths}))
