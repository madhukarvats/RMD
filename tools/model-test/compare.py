# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = [
#   "numpy",
#   "torch",
#   "transformers>=4.56",
#   "accelerate",
#   "huggingface_hub",
#   "cactus-needle",
# ]
# ///
"""Compare local speech-to-text models on your own voice clips.

    uv run tools/model-test/compare.py samples/my-day.m4a [more clips...]

Everything runs on this Mac; models are downloaded once from Hugging Face.
Stock Whisper turbo is run through the RMD app itself (`make build` first), so the
report shows exactly what the app would write.
Writes a side-by-side report next to each clip: <clip>.results.md
"""

import os

os.environ.setdefault("NEEDLE_TELEMETRY", "0")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")

import subprocess
import sys
import tempfile
import time
import wave
from pathlib import Path

import numpy as np

SR = 16_000
APP = Path(__file__).resolve().parents[2] / "build/Build/Products/Debug/RMD.app/Contents/MacOS/RMD"


def load_audio(path: Path) -> np.ndarray:
    pcm = subprocess.run(
        ["ffmpeg", "-nostdin", "-loglevel", "error", "-i", str(path),
         "-ac", "1", "-ar", str(SR), "-f", "s16le", "-"],
        check=True, capture_output=True,
    ).stdout
    return np.frombuffer(pcm, np.int16).astype(np.float32) / 32768


def write_wav(audio: np.ndarray, path: Path) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((np.clip(audio, -1, 1) * 32767).astype(np.int16).tobytes())


class HFWhisper:
    def __init__(self, repo: str, **generate_kwargs):
        import torch
        from transformers import pipeline

        device = "mps" if torch.backends.mps.is_available() else "cpu"
        self.pipe = pipeline(
            "automatic-speech-recognition",
            model=repo,
            dtype=torch.float16 if device == "mps" else torch.float32,
            device=device,
        )
        self.generate_kwargs = {"task": "transcribe", **generate_kwargs}

    def transcribe(self, audio: np.ndarray, wav: Path) -> str:
        out = self.pipe(
            {"raw": audio, "sampling_rate": SR},
            chunk_length_s=30,
            generate_kwargs=self.generate_kwargs,
        )
        return out["text"].strip()


class RMDApp:
    """The app's own pipeline: silence skipping + WhisperKit large-v3-turbo on the Neural Engine."""

    def __init__(self, language: str | None = None):
        if not APP.exists():
            sys.exit("Build the app first: make build")
        self.env = {**os.environ, **({"RMD_LANGUAGE": language} if language else {})}

    def transcribe(self, audio: np.ndarray, wav: Path) -> str:
        out = subprocess.run([str(APP), "--transcribe", str(wav)], env=self.env,
                             check=True, capture_output=True, text=True).stdout
        # Lines look like: +012.3s (4.1s speech, 0.6s to transcribe) [hi] text
        return "\n".join(line.split("] ", 1)[1] for line in out.splitlines()
                         if line.startswith("+") and "] " in line)


class Shruti:
    def __init__(self):
        from huggingface_hub import hf_hub_download
        from needle import Whistle

        self.model = Whistle(hf_hub_download("udgamlabs/Shruti", "shruti.cact"))

    def transcribe(self, audio: np.ndarray, wav: Path) -> str:
        return self.model.transcribe(str(wav))["text"].strip()


MODELS = {
    "RMD app — Whisper turbo, auto language": RMDApp,
    "RMD app — Whisper turbo, translate to English": lambda: RMDApp(language="en"),
    # The model card says to set language="en"; that is what makes it write Roman Hinglish.
    "Oriserve Hindi2Hinglish-Apex": lambda: HFWhisper("Oriserve/Whisper-Hindi2Hinglish-Apex", language="en"),
    "Shruti (Udgam Labs)": Shruti,
}


def main(paths: list[Path]) -> None:
    clips = []
    tmp = Path(tempfile.mkdtemp(prefix="rmd-model-test-"))
    for path in paths:
        audio = load_audio(path)
        wav = tmp / f"{path.stem}.wav"
        write_wav(audio, wav)
        clips.append((path, audio, wav))

    results: dict[Path, list[tuple[str, str, float]]] = {p: [] for p, _, _ in clips}
    for name, make in MODELS.items():
        print(f"\n=== {name}: loading…", flush=True)
        t0 = time.perf_counter()
        model = make()
        print(f"    loaded in {time.perf_counter() - t0:.1f}s", flush=True)
        model.transcribe(clips[0][1][: SR * 2], clips[0][2])  # warm-up
        for path, audio, wav in clips:
            t0 = time.perf_counter()
            text = model.transcribe(audio, wav)
            secs = time.perf_counter() - t0
            results[path].append((name, text, secs))
            print(f"--- {path.name} ({secs:.1f}s)\n{text}", flush=True)
        del model

    for path, audio, _ in clips:
        duration = len(audio) / SR
        lines = [f"# {path.name} ({duration:.0f}s of audio)\n"]
        for name, text, secs in results[path]:
            lines.append(f"## {name}\n_{secs:.1f}s to transcribe ({duration / secs:.0f}× faster than real time)_\n\n{text}\n")
        report = path.parent / f"{path.name}.results.md"
        report.write_text("\n".join(lines))
        print(f"\nReport: {report}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main([Path(p) for p in sys.argv[1:]])
