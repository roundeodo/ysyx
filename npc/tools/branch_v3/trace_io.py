"""Read immutable event evidence before or after lossless gzip compression."""
import gzip
import hashlib
from pathlib import Path


def open_text(path):
    path = Path(path)
    if path.suffix == '.gz':
        return gzip.open(path, 'rt')
    try:
        return path.open()
    except FileNotFoundError:
        return gzip.open(Path(str(path)+'.gz'), 'rt')


def event_files(directory):
    directory = Path(directory)
    logical = set(directory.glob('*.events'))
    logical.update(path.with_suffix('') for path in directory.glob('*.events.gz'))
    return sorted(logical)


def sha_uncompressed(path):
    path = Path(path)
    try:
        stream = gzip.open(path, 'rb') if path.suffix == '.gz' else path.open('rb')
    except FileNotFoundError:
        stream = gzip.open(Path(str(path)+'.gz'), 'rb')
    digest = hashlib.sha256()
    with stream:
        for chunk in iter(lambda: stream.read(1048576), b''):
            digest.update(chunk)
    return digest.hexdigest()
