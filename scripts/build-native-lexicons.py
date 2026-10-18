# coding: utf-8
"""Build offline native-word membership lists; development-only dependency: spylls==0.1.7.

Run with the venv Python. Original frequency resources are retained verbatim; generated
lists validate membership only and do not autocorrect ordinary spelling errors.
"""
from pathlib import Path
from urllib.request import urlretrieve
from spylls.hunspell import Dictionary

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / '.build' / 'lexicons'
OUT = ROOT / 'Sources' / 'SwitchCore' / 'Resources'
COMMIT = '589a31b2c7e8a592270012e111a51a80d0176f6e'
CACHE.mkdir(parents=True, exist_ok=True)

for language, name in [('ru', 'ru_RU'), ('uk', 'uk_UA')]:
    base = f'https://raw.githubusercontent.com/LibreOffice/dictionaries/{COMMIT}/{name}/'
    for filename in [name + '.aff', name + '.dic', 'README_' + name + '.txt']:
        destination = CACHE / filename
        if not destination.exists():
            urlretrieve(base + filename, destination)
    dictionary = Dictionary.from_files(str(CACHE / name))
    accepted = []
    for line in (OUT / (language + '.txt')).read_text(encoding='utf-8').splitlines():
        word = line.split()[0]
        if dictionary.lookup(word) or dictionary.lookup(word[:1].upper() + word[1:]):
            accepted.append(word)
    (OUT / (language + '-native.txt')).write_text('\n'.join(accepted) + '\n', encoding='utf-8')
    (OUT / ('LICENSE_' + name + '.txt')).write_bytes((CACHE / ('README_' + name + '.txt')).read_bytes())
    print(language, len(accepted), 'accepted frequency words', flush=True)

urlretrieve('https://raw.githubusercontent.com/spdx/license-list-data/main/text/MPL-1.1.txt', OUT / 'MPL-1.1.txt')
