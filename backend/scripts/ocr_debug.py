"""
Shows what each OCR variant makes of ONE image, to diagnose a receipt the system
read badly (for example the one showing "Vendor not found" with 0% confidence).

Usage:
    cd backend
    python3 scripts/ocr_debug.py path/to/image.jpg
"""
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))


def main(path):
    from PIL import Image
    from app.services.extraction import extract_fields
    from app.services.ocr import VARIANTS, ocr

    im = Image.open(path)
    print(f"{path}\n  size={im.size} mode={im.mode} format={im.format} exif_orientation={im.getexif().get(274)}")
    for name in VARIANTS:
        text = ocr(path, name)
        ex = extract_fields(text)
        lines = [l for l in text.splitlines() if l.strip()]
        print(f"\n--- {name}: {len(lines)} lines | company={ex.company.value!r} date={ex.date.value!r} total={ex.total.value!r}")
        for l in lines[:6]:
            print("    ", l[:78])


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: python3 scripts/ocr_debug.py <image path>")
    main(sys.argv[1])
