"""Send three tutorial screenshots together in one Codex request."""
import json
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent
APP = ROOT / 'Lens.app/Contents/MacOS/Lens'
with tempfile.TemporaryDirectory(prefix='lens-batch-check-') as folder:
    files = []
    expected = ['25.00', 'C', '1, 3, 5']
    for index, flags in enumerate([[], ['--choice'], ['--multi-bullets']]):
        image = Path(folder) / f'{index+1}.png'
        subprocess.run([str(APP), '--make-fixture', str(image), *flags], check=True)
        files.append(str(image))
    start = time.monotonic()
    process = subprocess.run([str(APP), '--solve-batch', *files], capture_output=True, text=True, timeout=900)
    if process.returncode:
        raise RuntimeError(process.stderr)
    result = json.loads(process.stdout)
    actual = [item['result']['answer'] for item in result['items']]
    assert actual == expected, result
    assert [item['image_index'] for item in result['items']] == [1, 2, 3], result
    assert all(item['result']['status'] == 'ok' and item['result']['solution'].strip() for item in result['items']), result
    report = {'images': 3, 'cli_requests': 1, 'expected': expected, 'actual': actual,
              'seconds': round(time.monotonic()-start, 1), 'response': result}
    (ROOT / 'batch-live-test-results.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(json.dumps({key: value for key, value in report.items() if key != 'response'}, ensure_ascii=False, indent=2))
