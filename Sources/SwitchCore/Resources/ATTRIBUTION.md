# Frequency dictionaries

Source: [FrequencyWords](https://github.com/hermitdave/FrequencyWords), Hermit Dave.
Files: content/2018/{en,de,ru,uk}/{language}_50k.txt (retrieved 2026-10-17).
The Ukrainian file uses the upstream `_full.txt` fallback if `_50k.txt` is unavailable.
Underlying corpus: OpenSubtitles 2018, OPUS.

Content license: [Creative Commons Attribution-ShareAlike 4.0 International](https://creativecommons.org/licenses/by-sa/4.0/).
The word-list bytes are redistributed without modification. File names have been shortened.
This license applies to the dictionaries; the application source is separate.

## Native-word membership lists (0.1.4)

`ru-native.txt` and `uk-native.txt` are modified, generated intersections of the above
frequency lists with the LibreOffice Hunspell dictionaries (including inflections and
capitalized entries). They validate language membership; spelling suggestions are not used.
Generation: `scripts/build-native-lexicons.py`, development tool Spylls 0.1.7.

Pinned source: https://github.com/LibreOffice/dictionaries/tree/589a31b2c7e8a592270012e111a51a80d0176f6e

- Russian: `ru_RU`, Copyright (c) 1997–2008 Alexander I. Lebedev; modifications by
  Laszlo Nemeth. Redistribution terms and disclaimer: `LICENSE_ru_RU.txt`.
- Ukrainian: `uk_UA`, based on the dict_uk project, package author Andriy Rysin,
  2007–2017. Mozilla Public License 1.1. Notices: `LICENSE_uk_UA.txt`;
  complete license: `MPL-1.1.txt`. Upstream: https://github.com/brown-uk/dict_uk

The generated lists are available as source in this directory. Frequency list attribution
and CC BY-SA 4.0 terms above also remain applicable. No Hunspell engine or Python package
is included in the application, and no dictionary lookup uses the network.

## Authored vocabulary additions (0.1.7)

`ru-supplemental.txt` initially contained ten manually written inflections of «браузер».
The language supplemental lists have since been extended with authored everyday
vocabulary and inflections, including «переключались» and «комп'ютер» in 0.2.1.
They are separate from the upstream corpora and generated native membership lists.
These entries use a conservative fallback rank of 10,000, not an estimated corpus frequency.
Version 0.2.3 adds the authored entries `github` and `изучи` for reported layout-conversion misses.

Version 0.2.2 adds 148 authored Ukrainian forms containing an apostrophe. The
upstream frequency and generated membership files remain unchanged.

## Root-zone suffix list (0.1.8)

`tlds-alpha-by-domain.txt`: IANA, https://data.iana.org/TLD/tlds-alpha-by-domain.txt,
retrieved 2026-10-18. Version and update date are retained in the file header.
Used only for offline web-address syntax recognition; no DNS or registration check.
