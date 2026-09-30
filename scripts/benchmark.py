#!/usr/bin/env python3
"""Measure real worker validation and conversion on disposable synthetic media."""
import argparse
import json
import pathlib
import statistics
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('app', type=pathlib.Path)
parser.add_argument('report', type=pathlib.Path)
parser.add_argument('--runs', type=int, default=3)
args = parser.parse_args()
app = args.app.resolve()
worker = app / 'Contents/Helpers/RenamorphWorker'
ffmpeg = app / 'Contents/Helpers/Media/ffmpeg'
root = pathlib.Path(__file__).resolve().parent.parent / 'test-artifacts/benchmark'
root.mkdir(parents=True, exist_ok=True)
audio, video = root / 'source.wav', root / 'source.mov'
if not audio.exists():
    subprocess.run([str(ffmpeg), '-v', 'error', '-f', 'lavfi', '-i', 'sine=sample_rate=48000', '-t', '30', '-ac', '2', '-c:a', 'pcm_s24le', str(audio)], check=True)
if not video.exists():
    subprocess.run([str(ffmpeg), '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=25', '-f', 'lavfi', '-i', 'sine=sample_rate=48000', '-t', '10', '-ac', '2', '-threads', '1', '-c:v', 'libx264', '-preset', 'medium', '-crf', '23', '-c:a', 'aac', str(video)], check=True)

def perform(directory, action, source, target=None, output=None, mode='preferRemux'):
    request = {'action': action, 'input': str(source), 'options': {'jpegQuality': .9, 'alpha': 'reject', 'audioBitrate': 192, 'audioSampleRate': 0, 'videoCRF': 23, 'mediaMode': mode}, 'maxPixels': 40000000, 'maxBytes': 2147483648}
    if target:
        request.update(target=target, output=str(output))
    input_json, output_json = directory / 'request.json', directory / 'response.json'
    input_json.write_text(json.dumps(request))
    process = subprocess.run([str(worker), str(input_json), str(output_json)], capture_output=True, timeout=120)
    response = json.loads(output_json.read_text()) if output_json.exists() else {}
    if process.returncode or response.get('error') or not response.get('info'):
        raise RuntimeError(str(response) + process.stderr.decode(errors='replace'))
    return response['info']

scenarios = [('inspect_audio', audio, None, 'preferRemux'), ('inspect_video', video, None, 'preferRemux'), ('wav_to_mp3', audio, 'mp3', 'transcode'), ('mov_to_mkv_remux', video, 'mkv', 'remuxOnly'), ('mov_to_mp4_transcode', video, 'mp4', 'transcode')]
report = {'app': str(app), 'os': subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip(), 'architecture': subprocess.check_output(['uname', '-m'], text=True).strip(), 'engine': subprocess.check_output([str(ffmpeg), '-version'], text=True).splitlines()[0], 'fixture': {'audio': '30s 48kHz stereo PCM24', 'video': '10s 1280x720 25fps H264 CRF23 + AAC'}, 'runs': args.runs, 'scenarios': {}}
for name, source, target, mode in scenarios:
    elapsed = []
    for index in range(args.runs):
        with tempfile.TemporaryDirectory(prefix='run-', dir=root) as temporary:
            directory = pathlib.Path(temporary)
            output = directory / 'output'
            started = time.perf_counter()
            info = perform(directory, 'convert' if target else 'inspect', source, target, output, mode)
            if target:
                result = perform(directory, 'inspect', output)
                assert result['format'] == target
                assert abs(result['media']['duration'] - info['media']['duration']) <= .25
                if info['media'].get('videoFrames'):
                    assert result['media']['videoFrames'] == info['media']['videoFrames']
                    assert result['media']['videoTimingDigest'] == info['media']['videoTimingDigest']
            elapsed.append(time.perf_counter() - started)
    report['scenarios'][name] = {'seconds': elapsed, 'median': statistics.median(elapsed)}
    print(name, round(statistics.median(elapsed), 3), flush=True)
args.report.parent.mkdir(parents=True, exist_ok=True)
args.report.write_text(json.dumps(report, indent=2) + '\n')
