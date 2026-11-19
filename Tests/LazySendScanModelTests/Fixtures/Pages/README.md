# Page photos

Six frames of the SmartDoc 2015 Challenge 1 dataset for the corner model's tests: one from each of
background01 to background04 and two from background05, the cluttered desk where our own page search does
worst (a cable across the page, more sheets under it, pens on it). Read by the Swift model tests
(`Tests/LazyScanModelTests`, found next to the test file) and copied next to the C# test assembly
by `windows/LazyScan.App.Tests`.

The frames are 1920 × 1080 in the dataset. Here they are scaled to 1280 × 720 (Lanczos) and saved as
JPEG at quality 90, and their ground-truth corners scaled by the same 2/3. `corners.json` lists each file
with its size and the page's corners in its pixels, as the dataset names them: by the page's own top, so
in `background04-tax004-0125.jpg`, whose page lies on its side, `topLeft` is the corner at the lower
left. Compare them by position (`Quad.fromCorners`).

| File | Dataset frame |
|---|---|
| `background01-magazine004-0157.jpg` | `background01/magazine004/frame_0157.jpeg` |
| `background02-letter001-0141.jpg` | `background02/letter001/frame_0141.jpeg` |
| `background03-paper004-0111.jpg` | `background03/paper004/frame_0111.jpeg` |
| `background04-tax004-0125.jpg` | `background04/tax004/frame_0125.jpeg` |
| `background05-paper002-0055.jpg` | `background05/paper002/frame_0055.jpeg` |
| `background05-patent002-0045.jpg` | `background05/patent002/frame_0045.jpeg` |

Source: https://github.com/jchazalon/smartdoc15-ch1-dataset, release v2.0.0, `frames.tar.gz`
(SHA-256 `3acb8be143fc86c507d90d298097cba762e91a3abf7e2d35ccd5303e13a79eae`) with its `metadata.csv.gz`.

## Licence and attribution

The SmartDoc 2015 Challenge 1 dataset is licensed under the Creative Commons Attribution 4.0
International License (https://creativecommons.org/licenses/by/4.0/). These files are changed from the
original: scaled down and re-encoded as described above.

Jean-Christophe Burie, Joseph Chazalon, Mickaël Coustaty, Sébastien Eskenazi, Muhammad Muzzamil Luqman,
Maroua Mehri, Nibal Nayef, Jean-Marc Ogier, Sophea Prum and Marçal Rusiñol: "ICDAR2015 Competition on
Smartphone Document Capture and OCR (SmartDoc)", in 13th International Conference on Document Analysis
and Recognition (ICDAR), 2015.

DocAligner's models may have been trained on SmartDoc, so they do better on these frames than they
would on photos they have never seen.
