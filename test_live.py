"""Run image-to-answer checks against the signed-in Codex account."""
import json
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent
APP = ROOT / "Lens.app/Contents/MacOS/Lens"
results = []
with tempfile.TemporaryDirectory(prefix="econ-lens-check-") as directory:
    for name, expected, extra in [("monopoly", "25,00", []), ("lerner", "C", ["--choice"]), ("multiple_letters", "A, C, E", ["--multi-letters"]), ("multiple_bullets", "1, 3, 5", ["--multi-bullets"])]:
        image = Path(directory) / f"{name}.png"
        subprocess.run([str(APP), "--make-fixture", str(image), *extra], check=True)
        start = time.monotonic()
        response = subprocess.run([str(APP), "--solve", str(image)], capture_output=True, text=True, timeout=900)
        if response.returncode:
            raise RuntimeError(f"{name}: {response.stderr}")
        answer = json.loads(response.stdout)
        assert answer["status"] == "ok", answer
        assert answer["answer"] == expected, answer
        assert answer["solution"].strip(), answer
        results.append({"case": name, "expected": expected, "actual": answer["answer"],
                        "seconds": round(time.monotonic()-start, 1), "response": answer})
    invalid = Path(directory) / "invalid.png"
    invalid.write_text("not an image")
    response = subprocess.run([str(APP), "--solve", str(invalid)], capture_output=True, text=True, timeout=5)
    assert response.returncode != 0
    results.append({"case": "invalid_image", "result": "rejected before inference"})
report = ROOT / "live-test-results.json"
report.write_text(json.dumps(results, ensure_ascii=False, indent=2))
print(json.dumps([{key: value for key, value in result.items() if key != "response"} for result in results], ensure_ascii=False, indent=2))
