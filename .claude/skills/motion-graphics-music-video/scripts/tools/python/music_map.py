#!/usr/bin/env python3
"""Music map for sync work (numpy + scipy): beats with a local tempo map, drum hits, vocal onsets and sections.

usage:
  music_map.py all      song.wav out_dir [--stems DIR] [--fps 24] [--min-bpm 80] [--max-bpm 180] [--tempo auto]
  music_map.py beats    song.wav out.json [--drums drums.wav] [--fps 24] [--min-bpm 80] [--max-bpm 180]
  music_map.py hits     drums.wav out.json [--beats beatmap.json] [--bass bass.wav]
  music_map.py vocals   vocals.wav out.json [--beats beatmap.json]   (lines ~ lyric lines, phrases ~ words, onsets)
  music_map.py sections song.wav out.json --beats beatmap.json [--hits hits.json] [--vocals vocals.json]

`all` writes beatmap.json, hits.json, vocals.json (when DIR/vocals.wav exists) and sections.json into out_dir.
With --stems, drums come from DIR/drums.wav (else DIR/no_vocals.wav, else the mix) and 808 notes from DIR/bass.wav.
All times are seconds of the input file. Prints a JSON summary on stdout.

beats: spectral-flux onset envelope -> autocorrelation tempo, refined by a whole-song comb fit -> phase-locked comb
tracking (period +-1.2%, phase continuity) every 4 beats, so the grid follows tempo drift (generated songs often shift
tempo at section joins) without locking to syncopated onsets. tempo "auto" reports one straight grid when the tracked
grid never strays > 25 ms from a line, else the local map. `raw` = strongest onset within 8% of a period of each beat.
Downbeat phase = the phase whose beats carry the most kick and whose snare lands on the backbeat (2/4) or half-time 3.
hits: band-filtered energy envelopes at 1 ms; an event is a fast dB rise; its time is the half-rise point of the
attack (not the energy peak). Kick (or 808 attack) 30-150 Hz, snare/clap 1-5 kHz, hat 7-16 kHz; a hat co-detected with a stronger
snare is dropped. Each hit gets beat (fractional), bar and step (16th in bar); bars carry 16-step patterns.
"""
import argparse
import json
import os
import sys

import numpy as np
import soundfile as sf
from scipy.signal import butter, find_peaks, sosfiltfilt


# ------------------------------------------------------------------ io / dsp
def load(path):
    y, sr = sf.read(path, always_2d=True, dtype="float32")
    return y.mean(axis=1), sr


def stft_mag(y, sr, n_fft, hop):
    """Centered frames: frame i is centered on i*hop/sr. Computed in chunks to bound memory."""
    pad = n_fft // 2
    yp = np.pad(y, (pad, pad))
    n = 1 + (len(yp) - n_fft) // hop
    win = np.hanning(n_fft).astype(np.float32)
    out = np.empty((n, n_fft // 2 + 1), dtype=np.float32)
    step = 4096
    for a in range(0, n, step):
        b = min(n, a + step)
        idx = (np.arange(a, b)[:, None] * hop) + np.arange(n_fft)[None, :]
        out[a:b] = np.abs(np.fft.rfft(yp[idx] * win, axis=1))
    return out, np.arange(n) * hop / sr, np.fft.rfftfreq(n_fft, 1 / sr)


def band_flux(mag, freqs, lo, hi):
    a, b = np.searchsorted(freqs, lo), max(np.searchsorted(freqs, hi), np.searchsorted(freqs, lo) + 1)
    L = np.log1p(1000 * mag[:, a:b])
    d = np.diff(L, axis=0, prepend=L[:1])
    return np.maximum(d, 0).sum(axis=1)


def band_db(y, sr, lo, hi, hop_s=0.001, win_s=0.005):
    """Energy envelope (dB) of a band, sampled every hop_s with a win_s moving average."""
    nyq = sr / 2
    if lo <= 0:
        sos = butter(4, hi / nyq, btype="low", output="sos")
    elif hi >= nyq * 0.98:
        sos = butter(4, lo / nyq, btype="high", output="sos")
    else:
        sos = butter(4, [lo / nyq, hi / nyq], btype="band", output="sos")
    p = sosfiltfilt(sos, y.astype(np.float64)) ** 2
    c = np.concatenate([[0.0], np.cumsum(p)])
    w, h = max(1, int(win_s * sr)), max(1, int(hop_s * sr))
    centers = np.arange(0, len(y), h)
    a, b = np.clip(centers - w // 2, 0, len(y)), np.clip(centers + w // 2 + 1, 0, len(y))
    e = (c[b] - c[a]) / np.maximum(b - a, 1)
    return 10 * np.log10(e + 1e-12), h / sr  # actual hop (int samples), not the requested hop_s


def norm(x):
    s = np.std(x)
    return x / s if s > 0 else x


# ------------------------------------------------------------------ beats
def tempo(env, hop_s, min_bpm, max_bpm):
    e = env - env.mean()
    n = len(e)
    f = np.fft.rfft(e, 2 * n)
    ac = np.fft.irfft(f * np.conj(f))[:n]
    lo, hi = int(60 / max_bpm / hop_s), int(60 / min_bpm / hop_s) + 1
    k = lo + int(np.argmax(ac[lo:hi]))
    # Parabolic interpolation for sub-frame period accuracy.
    if lo < k < hi - 1:
        a, b, c = ac[k - 1], ac[k], ac[k + 1]
        k = k + 0.5 * (a - c) / (a - 2 * b + c + 1e-12)
    return k * hop_s


def local_comb(env, hop_s, period, half=16, step=4, drift=0.012, slip=0.15):
    """Phase-locked comb tracking. Every `step` beats, fit (period, phase) maximizing Gaussian-weighted onset energy on
    a +-`half`-beat grid; the period may differ by +-drift from the global one and the phase may move by +-slip of a
    period from the prediction (continuity prevents locking to off-beats). Silent windows keep the prediction.
    Returns anchor beats exactly `step` beats apart."""
    t = np.arange(len(env)) * hop_s
    k = np.arange(-half, half + 1)
    w = np.exp(-0.5 * (k / (half / 2)) ** 2)
    Ps = period * (1 + np.linspace(-drift, drift, 49))
    def fit(base, offs):
        best = (-1.0, base, period)
        for P in Ps:
            v = (np.interp((base + offs)[:, None] + k[None, :] * P, t, env, left=0, right=0) * w).sum(axis=1)
            j = int(np.argmax(v))
            if v[j] > best[0]:
                best = (float(v[j]), base + offs[j], P)
        return best
    # Lock the first anchor where the music is strong, then walk outward in both directions.
    centers = np.arange(half * period, t[-1] - half * period, step * period)
    if len(centers) == 0:
        centers = np.array([t[-1] / 2])
    probes = [fit(c, np.arange(-period / 2, period / 2, hop_s)) for c in centers]
    start = int(np.argmax([p[0] for p in probes]))
    ref = np.median([p[0] for p in probes])
    anchors = {0: (probes[start][1], probes[start][2])}
    narrow = np.arange(-slip * period, slip * period, hop_s)
    for direction in (1, -1):
        b, P, i = probes[start][1], probes[start][2], 0
        while True:
            i += direction
            base = b + direction * step * P
            if base < -0.5 * period or base > t[-1] + 0.5 * period:
                break
            score, nb, nP = fit(base, narrow)
            if score < 0.25 * ref:
                nb, nP = base, P
            anchors[i] = (nb, nP)
            b, P = nb, nP
    idx = sorted(anchors)
    return np.array([anchors[i][0] for i in idx]), np.array([anchors[i][1] for i in idx])


def smooth_grid(raw, half=8):
    """Local robust linear fit of beat time vs index: keeps tempo drift, removes per-beat jitter."""
    n = len(raw)
    idx = np.arange(n)
    out = np.empty(n)
    for k in range(n):
        a, b = max(0, k - half), min(n, k + half + 1)
        x, y = idx[a:b], raw[a:b]
        keep = np.ones(len(x), bool)
        for _ in range(3):
            if keep.sum() < 3:
                break
            m, c = np.polyfit(x[keep], y[keep], 1)
            r = np.abs(y - (m * x + c))
            keep = r < max(0.03, 2.5 * np.median(r[keep]))
        out[k] = m * k + c
    return out


def comb_fit(env, hop_s, period, span=0.008):
    """Constant-tempo grid maximizing onset energy at beat times: fine period (+-span) and phase search."""
    t = np.arange(len(env)) * hop_s
    phases = np.arange(0, period, hop_s)
    best = (-1, period, 0.0)
    for P in period * (1 + np.linspace(-span, span, 161)):
        n = int((t[-1] - P) / P)
        if n < 2:
            continue
        v = np.interp(phases[:, None] + np.arange(n)[None, :] * P, t, env).sum(axis=1)
        k = int(np.argmax(v))
        if v[k] > best[0]:
            best = (v[k], P, phases[k])
    return best[1], best[2]


def peak_near(sig, times, t, w=0.035):
    a, b = np.searchsorted(times, t - w), np.searchsorted(times, t + w)
    return float(sig[a:b].max()) if b > a else 0.0


def beats_cmd(song, drums=None, fps=24.0, min_bpm=80, max_bpm=180, tempo_mode="auto"):
    y, sr = load(song)
    mag, times, freqs = stft_mag(y, sr, 1024, 256)
    hop_s = 256 / sr
    env = band_flux(mag, freqs, 30, 11000)
    # Remove slow loudness swells (0.5 s moving average) so onsets, not sections, drive tracking.
    k = max(1, int(0.5 / hop_s))
    env = np.maximum(env - np.convolve(env, np.ones(k) / k, "same"), 0)
    env = norm(env)
    period = tempo(env, hop_s, min_bpm, max_bpm)
    # The autocorrelation period is only ~0.3% accurate; a comb fit over the whole song pins it (and the phase).
    period, phase0 = comb_fit(env, hop_s, period)
    step = 4
    anchors, _ = local_comb(env, hop_s, period, step=step)
    local = np.concatenate([np.linspace(a, b, step, endpoint=False) for a, b in zip(anchors[:-1], anchors[1:])] + [anchors[-1:]])
    # Extend past the outermost anchors with the edge periods to cover the whole file; silence is trimmed below.
    p0, p1 = anchors[1] - anchors[0] if len(anchors) > 1 else period, anchors[-1] - anchors[-2] if len(anchors) > 1 else period
    p0, p1 = p0 / step if len(anchors) > 1 else p0, p1 / step if len(anchors) > 1 else p1
    head = local[0] - p0 * np.arange(int(local[0] / p0) + 1, 0, -1)
    tail = local[-1] + p1 * np.arange(1, int((len(y) / sr - local[-1]) / p1) + 1)
    local = smooth_grid(np.concatenate([head, local, tail]))
    # Constant tempo (typical of produced tracks) when the locally tracked grid never strays from one straight line.
    n = np.arange(len(local))
    m, c = np.polyfit(n, local, 1)
    stray = float(np.abs(local - (m * n + c)).max())
    mode = tempo_mode if tempo_mode != "auto" else ("constant" if stray < 0.025 else "local")
    grid = m * n + c if mode == "constant" else local
    # Trim beats in leading/trailing silence.
    level = np.convolve(env, np.ones(int(2 / hop_s)) / int(2 / hop_s), "same")
    lv = np.interp(grid, times, level)
    alive = np.flatnonzero(lv > 0.1 * np.median(lv))
    if len(alive):
        grid = grid[alive[0]:alive[-1] + 1]
    grid = grid[(grid >= 0) & (grid <= len(y) / sr)]
    # raw = strongest onset within +-8% of a period of each grid beat (the beat if none).
    raw = []
    for g in grid:
        a_, b_ = np.searchsorted(times, g - 0.08 * period), np.searchsorted(times, g + 0.08 * period)
        raw.append(times[a_ + int(np.argmax(env[a_:b_]))] if b_ > a_ and env[a_:b_].max() > 0.5 else g)
    raw = np.array(raw)

    # Downbeat phase from kick / snare energy at each beat (drum stem if available).
    dy, dsr = load(drums) if drums else (y, sr)
    dmag, dtimes, dfreqs = stft_mag(dy, dsr, 2048, 256)
    kick = norm(band_flux(dmag, dfreqs, 30, 150))
    snare = norm(band_flux(dmag, dfreqs, 1000, 5000))
    K = np.array([peak_near(kick, dtimes, t) for t in grid])
    S = np.array([peak_near(snare, dtimes, t) for t in grid])
    best = None
    for p in range(4):
        n = np.arange(len(grid))
        kd = K[(n - p) % 4 == 0].mean()
        backbeat = S[(n - p) % 2 == 1].mean() - S[(n - p) % 2 == 0].mean()
        halftime = S[(n - p) % 4 == 2].mean() - S[(n - p) % 4 != 2].mean()
        for name, sn in (("backbeat", backbeat), ("halftime", halftime)):
            score = kd - K.mean() + sn
            if best is None or score > best[0]:
                best = (score, p, name)
    _, phase, feel = best

    beats = []
    for n, (t, r) in enumerate(zip(grid, raw)):
        rel = n - phase
        beats.append({"n": n, "t": round(float(t), 4), "raw": round(float(r), 4), "bar": int(rel // 4), "pos": int(rel % 4),
                      "f": int(round(t * fps)), "kick": round(float(K[n]), 2), "snare": round(float(S[n]), 2)})
    bars = []
    for b in sorted({x["bar"] for x in beats}):
        bt = [x["t"] for x in beats if x["bar"] == b]
        if len(bt) >= 2:
            bars.append({"bar": b, "t": bt[0] if beats[[x["bar"] for x in beats].index(b)]["pos"] == 0 else None,
                         "bpm": round(60 / float(np.mean(np.diff(bt))), 2)})
    for row in bars:
        if row["t"] is None:
            first = next(x for x in beats if x["bar"] == row["bar"])
            row["t"] = round(first["t"] - first["pos"] * 60 / row["bpm"], 4)
    jitter = float(np.median(np.abs(raw - grid))) * 1000
    return {"source": os.path.abspath(song), "duration": round(len(y) / sr, 3), "fps": fps,
            "bpm": round(60 / float(np.median(np.diff(grid))), 3), "comb_bpm": round(60 / period, 3),
            "downbeat_phase": int(phase), "snare_feel": feel, "tempo_mode": mode, "stray_ms": round(stray * 1000, 1), "jitter_ms": round(jitter, 1),
            "beats": beats, "bars": bars}


# ------------------------------------------------------------------ hits
def detect(db, hop_s, rise_db, gap_s, floor_db, lookback_s=0.03, retrigger_s=0.15):
    lb = max(1, int(lookback_s / hop_s))
    # Rise = level now minus the minimum over the previous lookback window.
    from scipy.ndimage import minimum_filter1d
    mins = minimum_filter1d(db, size=lb, origin=(lb - 1) // 2)
    rise = db - np.concatenate([np.full(1, db[0]), mins[:-1]])
    pk, _ = find_peaks(rise, height=rise_db, distance=max(1, int(gap_s / hop_s)))
    out = []
    for i in pk:
        if db[i] < floor_db:
            continue
        # A quieter re-trigger shortly after a louder hit is its decay beating (kick over 808, snare ring), not a hit.
        if out and i * hop_s - out[-1][0] < retrigger_s and db[i] < out[-1][2] - 3:
            continue
        a = max(0, i - lb)
        # Half-rise in linear power: a centered smoothing window spreads a step symmetrically about the onset, so the
        # linear midpoint sits on it (the dB midpoint would lead by up to half the window).
        p = 10 ** (db[a:i + 1] / 10)
        target = p.min() + 0.5 * (p[-1] - p.min())
        j = a + int(np.argmax(p >= target))
        out.append((j * hop_s, float(rise[i]), float(db[i])))
    return out


def place(t, beat_t, phase):
    """Fractional beat index, bar and 16th step for time t against tracked beats."""
    if beat_t is None or len(beat_t) < 2:
        return {}
    n = float(np.interp(t, beat_t, np.arange(len(beat_t)), left=np.nan, right=np.nan))
    if np.isnan(n):
        # Extrapolate with the edge tempo.
        if t < beat_t[0]:
            n = (t - beat_t[0]) / (beat_t[1] - beat_t[0])
        else:
            n = len(beat_t) - 1 + (t - beat_t[-1]) / (beat_t[-1] - beat_t[-2])
    rel = n - phase
    q = int(np.floor(rel * 4 + 0.5))
    return {"beat": round(n, 3), "bar": int(np.floor(q / 16)), "step": int(q % 16)}


def note_name(hz):
    if hz <= 0:
        return None
    m = int(round(69 + 12 * np.log2(hz / 440)))
    return ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"][m % 12] + str(m // 12 - 1)


def hits_cmd(drums, beats=None, bass=None):
    y, sr = load(drums)
    peak = float(np.percentile(np.abs(y), 99.9)) + 1e-9
    top = 20 * np.log10(peak)
    # (lo Hz, hi Hz, min rise dB, min gap s, window s). The window must span a full cycle of the band's lowest
    # frequency, or the envelope ripples with the waveform and every bass cycle reads as an attack.
    bands = {"kick": (30, 150, 6, 0.09, 0.03), "snare": (1000, 5000, 8, 0.09, 0.006), "hat": (7000, 16000, 7, 0.05, 0.003)}
    found, lev = {}, {}
    for name, (lo, hi, rise, gap, win) in bands.items():
        db, hop_s = band_db(y, sr, lo, min(hi, sr / 2 * 0.98), win_s=win)
        lev[name] = (db, hop_s)
        found[name] = detect(db, hop_s, rise, gap, np.percentile(db, 99.5) - (24 if name == "kick" else 30), lookback_s=0.03 + win, retrigger_s=0.18 if name == "kick" else 0.6 * gap)
    def level(name, t):
        db, hop_s = lev[name]
        a = int(t / hop_s)
        return float(db[a:a + int(0.02 / hop_s) + 1].max()) if a < len(db) else -999.0
    # Spectral shape: a snare/clap carries real 1-5 kHz energy; a hat leaking into that band sits >10 dB under its own
    # 7-16 kHz level. A hat on a snare hit is masked by the snare and dropped.
    found["snare"] = [h for h in found["snare"] if level("snare", h[0]) >= level("hat", h[0]) - 10]
    sn = np.array([h[0] for h in found["snare"]])
    found["hat"] = [h for h in found["hat"] if not (len(sn) and np.min(np.abs(sn - h[0])) < 0.02)]
    beat_t = np.array([b["t"] for b in beats["beats"]]) if beats else None
    phase = beats["downbeat_phase"] if beats else 0
    out = {"source": os.path.abspath(drums)}
    for name, events in found.items():
        rises = np.array([e[1] for e in events]) if events else np.array([1.0])
        ref = np.percentile(rises, 95)
        out[name] = [{"t": round(t, 4), "s": round(min(1.0, r / ref), 2), "db": round(d - top, 1), **place(t, beat_t, phase)} for t, r, d in events]
    if bass:
        by, bsr = load(bass)
        db, hop_s = band_db(by, bsr, 25, 250, win_s=0.04)
        notes = []
        for t, r, d in detect(db, hop_s, 6, 0.1, np.percentile(db, 99.5) - 30):
            a = int(t * bsr) + int(0.02 * bsr)
            seg = by[a:a + int(0.15 * bsr)]
            hz = 0.0
            if len(seg) > 256:
                spec = np.abs(np.fft.rfft(seg * np.hanning(len(seg)), 8 * len(seg)))
                f = np.fft.rfftfreq(8 * len(seg), 1 / bsr)
                m = (f > 25) & (f < 250)
                hz = float(f[m][np.argmax(spec[m])])
            notes.append({"t": round(t, 4), "s": round(r, 1), "hz": round(hz, 1), "note": note_name(hz), **place(t, beat_t, phase)})
        out["bass"] = notes
    if beats:
        rows = {}
        for name in [k for k in ("kick", "snare", "hat", "bass") if k in out]:
            for h in out[name]:
                row = rows.setdefault(h["bar"], {k: ["."] * 16 for k in ("kick", "snare", "hat", "bass") if k in out})
                row[name][h["step"]] = "x"
        bar_t = {b["bar"]: b["t"] for b in beats["bars"]}
        out["bars"] = [{"bar": b, "t": bar_t.get(b), **{k: "".join(v) for k, v in rows[b].items()}} for b in sorted(rows)]
    return out


# ------------------------------------------------------------------ vocals
def vocals_cmd(vocals, beats=None):
    y, sr = load(vocals)
    db, hop_s = band_db(y, sr, 200, 5000, hop_s=0.005, win_s=0.02)
    # Stem separation leaves bleed ~25-35 dB under the voice; a gate 22 dB under the loud end keeps syllable gaps.
    gate = np.percentile(db, 99) - 22
    act = np.zeros(len(db), bool)
    state = False
    for i, v in enumerate(db):
        state = v > gate if not state else v > gate - 4  # hysteresis
        act[i] = state
    edges = np.flatnonzero(np.diff(np.concatenate([[0], act.astype(int), [0]])))
    def group(regions, gap, min_len):
        merged = []
        for s_, e_ in regions:
            if merged and s_ - merged[-1][1] < gap:
                merged[-1][1] = e_
            else:
                merged.append([s_, e_])
        return [(s_, e_) for s_, e_ in merged if e_ - s_ >= min_len]
    regions = group([(s_ * hop_s, e_ * hop_s) for s_, e_ in zip(edges[::2], edges[1::2])], 0.12, 0.1)
    peak = lambda s_, e_: round(float(db[int(s_ / hop_s):int(e_ / hop_s) + 1].max()), 1)
    # phrases ~ words / sung notes; lines ~ lyric lines (phrases closer than 0.6 s).
    phrases = [{"s": round(s_, 3), "e": round(e_, 3), "peak_db": peak(s_, e_)} for s_, e_ in regions]
    lines = [{"s": round(s_, 3), "e": round(e_, 3), "peak_db": peak(s_, e_)} for s_, e_ in group(regions, 0.6, 0.3)]
    mag, times, freqs = stft_mag(y, sr, 1024, 128)
    flux = band_flux(mag, freqs, 150, 6000)
    w = max(3, int(2.0 / (128 / sr)))
    from scipy.ndimage import median_filter
    med = median_filter(flux, size=w)
    mad = median_filter(np.abs(flux - med), size=w) + 1e-9
    pk, _ = find_peaks(flux, height=med + 1.5 * mad * 1.4826, distance=max(1, int(0.08 / (128 / sr))))
    beat_t = np.array([b["t"] for b in beats["beats"]]) if beats else None
    phase = beats["downbeat_phase"] if beats else 0
    ref = np.percentile(flux[pk], 95) if len(pk) else 1.0
    onsets = []
    for i in pk:
        t = float(times[i])
        if any(p["s"] - 0.02 <= t <= p["e"] for p in phrases):
            onsets.append({"t": round(t, 3), "s": round(min(1.0, float(flux[i] / ref)), 2), **place(t, beat_t, phase)})
    if beat_t is not None:
        for row in phrases + lines:
            row.update(place(row["s"], beat_t, phase))  # position of the phrase start
    return {"source": os.path.abspath(vocals), "gate_db": round(float(gate), 1), "lines": lines, "phrases": phrases, "onsets": onsets}


# ------------------------------------------------------------------ sections
def otsu(x):
    v = np.sort(np.asarray(x, float))
    best, thr = -1, v.mean()
    for i in range(1, len(v)):
        a, b = v[:i], v[i:]
        s = len(a) * len(b) * (a.mean() - b.mean()) ** 2
        if s > best:
            best, thr = s, (v[i - 1] + v[i]) / 2
    a, b = v[v <= thr], v[v > thr]
    sep = (b.mean() - a.mean()) if len(a) and len(b) else 0
    return thr, sep


def sections_cmd(song, beats, hits=None, vocals=None):
    y, sr = load(song)
    mag, times, freqs = stft_mag(y, sr, 4096, 1024)
    power = mag.astype(np.float64) ** 2
    def bdb(lo, hi):
        a, b = np.searchsorted(freqs, lo), np.searchsorted(freqs, hi)
        return 10 * np.log10(power[:, a:b].sum(axis=1) + 1e-12)
    feats = {"sub": bdb(20, 60), "low": bdb(60, 150), "mid": bdb(300, 2000), "high": bdb(6000, 16000), "rms": bdb(20, 16000)}
    starts = [b["t"] for b in beats["bars"]]
    rows = []
    for i, b in enumerate(beats["bars"]):
        t0 = b["t"]
        t1 = starts[i + 1] if i + 1 < len(starts) else t0 + 240 / b["bpm"]
        a, c = np.searchsorted(times, t0), np.searchsorted(times, t1)
        if c <= a:
            continue
        row = {"bar": b["bar"], "t": round(t0, 3), "end": round(t1, 3)}
        for k, v in feats.items():
            row[k] = round(float(v[a:c].mean()), 1)
        if hits:
            for k in ("kick", "snare", "hat"):
                row[k] = sum(1 for h in hits.get(k, []) if t0 <= h["t"] < t1)
        if vocals:
            on = sum(max(0, min(t1, p["e"]) - max(t0, p["s"])) for p in vocals["phrases"])
            row["vocal"] = round(on / (t1 - t0), 2)
        rows.append(row)
    states = {}
    for k in ("sub", "high", "rms"):
        thr, sep = otsu([r[k] for r in rows])
        states[k] = (thr, sep >= 6)
    for r in rows:
        r["state"] = {k: bool(r[k] > thr) if split else True for k, (thr, split) in states.items()}
        if vocals:
            r["state"]["vocal"] = bool(r["vocal"] >= 0.3)
    def label(s):
        if s["rms"] and s["sub"] and s["high"]:
            return "drop"
        if not s["sub"] and not s["rms"]:
            return "breakdown"
        if s["sub"] and not s["high"]:
            return "filtered"
        if not s["sub"] and s["high"]:
            return "build"
        return "groove"
    sections = []
    for r in rows:
        key = json.dumps(r["state"], sort_keys=True)
        if sections and sections[-1]["key"] == key:
            sections[-1]["end"] = r["end"]
            sections[-1]["end_bar"] = r["bar"]
            sections[-1]["rms_db"].append(r["rms"])
        else:
            sections.append({"key": key, "start_bar": r["bar"], "end_bar": r["bar"], "t": r["t"], "end": r["end"],
                             "label": label(r["state"]), "state": r["state"], "rms_db": [r["rms"]]})
    lo, hi = min(r["rms"] for r in rows), max(r["rms"] for r in rows)
    for s in sections:
        s.pop("key")
        s["bars"] = s["end_bar"] - s["start_bar"] + 1
        m = float(np.mean(s["rms_db"]))
        s["rms_db"] = round(m, 1)
        s["energy"] = round((m - lo) / (hi - lo + 1e-9), 2)
        if s["state"].get("vocal"):
            s["label"] += "+vox"
    return {"source": os.path.abspath(song), "thresholds": {k: {"db": round(float(t), 1), "split": bool(sp)} for k, (t, sp) in states.items()},
            "sections": sections, "bars": rows}


# ------------------------------------------------------------------ cli
def write(path, data):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["all", "beats", "hits", "vocals", "sections"])
    ap.add_argument("input")
    ap.add_argument("out")
    ap.add_argument("--stems"); ap.add_argument("--drums"); ap.add_argument("--bass")
    ap.add_argument("--beats"); ap.add_argument("--hits"); ap.add_argument("--vocals")
    ap.add_argument("--fps", type=float, default=24.0)
    ap.add_argument("--tempo", choices=["auto", "constant", "local"], default="auto")
    ap.add_argument("--min-bpm", type=float, default=80); ap.add_argument("--max-bpm", type=float, default=180)
    a = ap.parse_args()
    rd = lambda p: json.load(open(p)) if p else None
    if a.cmd == "beats":
        r = beats_cmd(a.input, a.drums, a.fps, a.min_bpm, a.max_bpm, a.tempo); write(a.out, r)
        print(json.dumps({"path": a.out, "bpm": r["bpm"], "tempo_mode": r["tempo_mode"], "beats": len(r["beats"]), "downbeat_phase": r["downbeat_phase"], "jitter_ms": r["jitter_ms"]}))
    elif a.cmd == "hits":
        r = hits_cmd(a.input, rd(a.beats), a.bass); write(a.out, r)
        print(json.dumps({"path": a.out, **{k: len(r[k]) for k in ("kick", "snare", "hat", "bass") if k in r}}))
    elif a.cmd == "vocals":
        r = vocals_cmd(a.input, rd(a.beats)); write(a.out, r)
        print(json.dumps({"path": a.out, "lines": len(r["lines"]), "phrases": len(r["phrases"]), "onsets": len(r["onsets"])}))
    elif a.cmd == "sections":
        if not a.beats:
            sys.exit("sections requires --beats beatmap.json")
        r = sections_cmd(a.input, rd(a.beats), rd(a.hits), rd(a.vocals)); write(a.out, r)
        print(json.dumps({"path": a.out, "sections": [[s["t"], s["label"], s["bars"]] for s in r["sections"]]}))
    else:
        stem = lambda n: os.path.join(a.stems, n) if a.stems and os.path.isfile(os.path.join(a.stems, n)) else None
        drums = stem("drums.wav") or stem("no_vocals.wav")
        beats = beats_cmd(a.input, drums, a.fps, a.min_bpm, a.max_bpm, a.tempo)
        hits = hits_cmd(drums or a.input, beats, stem("bass.wav"))
        vox = vocals_cmd(stem("vocals.wav"), beats) if stem("vocals.wav") else None
        secs = sections_cmd(a.input, beats, hits, vox)
        paths = {"beatmap": os.path.join(a.out, "beatmap.json"), "hits": os.path.join(a.out, "hits.json"),
                 "sections": os.path.join(a.out, "sections.json")}
        write(paths["beatmap"], beats); write(paths["hits"], hits); write(paths["sections"], secs)
        if vox:
            paths["vocals"] = os.path.join(a.out, "vocals.json"); write(paths["vocals"], vox)
        print(json.dumps({**paths, "bpm": beats["bpm"], "tempo_mode": beats["tempo_mode"], "downbeat_phase": beats["downbeat_phase"], "snare_feel": beats["snare_feel"],
                          "jitter_ms": beats["jitter_ms"], "hits": {k: len(hits[k]) for k in ("kick", "snare", "hat", "bass") if k in hits},
                          "sections": [[s["t"], s["label"], s["bars"]] for s in secs["sections"]]}))


if __name__ == "__main__":
    main()
