"""
OCR strategies for receipts. Tesseract's default call is tuned for clean document
scans; SROIE-style receipts are small, noisy and sometimes printed in colour, so we
keep several named variants (preprocessing + page-segmentation mode) and choose
between them with data (scripts/ocr_experiment.py), not by guesswork.

  raw           exactly what the app did before: default Tesseract on the untouched image
  raw_psm6      untouched image, "single uniform block of text" mode
  up_psm6       greyscale, upscaled to ~1500px wide, contrast-stretched, sharpened, psm 6
  up_psm4       same preprocessing, "single column" mode
  up_min_psm6   as up_psm6 but greyscale = darkest colour channel, so pink/red print stays dark
  otsu_psm6     as up_psm6, then hard black-and-white threshold (Otsu)
  up_psm11      as up_psm6, "sparse text" mode (finds scattered fragments)
"""
from typing import Callable, Dict, Optional, Tuple

import pytesseract
from PIL import Image, ImageChops, ImageFilter, ImageOps

TARGET_WIDTH = 1500   # Tesseract reads small print poorly; scale small receipts up to about this width
MAX_SCALE = 4.0


def _upscale(img: Image.Image) -> Image.Image:
    scale = min(max(TARGET_WIDTH / img.width, 1.0), MAX_SCALE)
    if scale < 1.05:
        return img
    return img.resize((round(img.width * scale), round(img.height * scale)), Image.LANCZOS)


def _gray(img: Image.Image) -> Image.Image:
    return ImageOps.grayscale(img)


def _darkest_channel(img: Image.Image) -> Image.Image:
    r, g, b = img.split()
    return ImageChops.darker(ImageChops.darker(r, g), b)


def _enhance(g: Image.Image) -> Image.Image:
    return ImageOps.autocontrast(g, cutoff=1).filter(ImageFilter.SHARPEN)


def otsu_threshold(g: Image.Image) -> int:
    """Threshold that best separates dark text from light paper (Otsu's method)."""
    hist = g.histogram()
    total = sum(hist)
    sum_all = sum(i * h for i, h in enumerate(hist))
    w_b = sum_b = 0
    best_var, best_t = -1.0, 127
    for t in range(256):
        w_b += hist[t]
        if w_b == 0:
            continue
        w_f = total - w_b
        if w_f == 0:
            break
        sum_b += t * hist[t]
        m_b, m_f = sum_b / w_b, (sum_all - sum_b) / w_f
        var = w_b * w_f * (m_b - m_f) ** 2
        if var > best_var:
            best_var, best_t = var, t
    return best_t


def _binarize(g: Image.Image) -> Image.Image:
    t = otsu_threshold(g)
    return g.point(lambda p: 255 if p > t else 0)


Prep = Callable[[Image.Image], Image.Image]
VARIANTS: Dict[str, Tuple[Prep, Optional[int]]] = {
    "raw": (lambda im: im, None),
    "raw_psm6": (lambda im: im, 6),
    "up_psm6": (lambda im: _enhance(_gray(_upscale(im))), 6),
    "up_psm4": (lambda im: _enhance(_gray(_upscale(im))), 4),
    "up_min_psm6": (lambda im: _enhance(_darkest_channel(_upscale(im))), 6),
    "otsu_psm6": (lambda im: _binarize(_enhance(_gray(_upscale(im)))), 6),
    "up_psm11": (lambda im: _enhance(_gray(_upscale(im))), 11),
}


def ocr(image_path: str, variant: str, timeout: int = 60) -> str:
    """Run one named OCR variant on an image file and return the raw text."""
    prep, psm = VARIANTS[variant]
    img = Image.open(image_path)
    if variant != "raw":  # "raw" must stay byte-for-byte what the app did before
        img = ImageOps.exif_transpose(img).convert("RGB")
    config = f"--psm {psm}" if psm else ""
    return pytesseract.image_to_string(prep(img), config=config, timeout=timeout)
