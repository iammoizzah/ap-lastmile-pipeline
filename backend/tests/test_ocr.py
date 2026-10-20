"""Tests for the OCR strategies. The OCR-running tests are skipped if Tesseract isn't installed."""
import os
import shutil

import pytest
from PIL import Image, ImageDraw, ImageFont

from app.services import ocr as ocr_mod

needs_tesseract = pytest.mark.skipif(shutil.which("tesseract") is None, reason="tesseract not installed")


def test_variants_include_the_untouched_baseline_and_all_psm_modes():
    assert {"raw", "raw_psm6", "up_psm6", "up_psm4", "up_min_psm6", "otsu_psm6", "up_psm11"} <= set(ocr_mod.VARIANTS)
    assert ocr_mod.VARIANTS["raw"][1] is None  # default Tesseract call, as before


def test_otsu_separates_dark_text_from_light_paper():
    img = Image.new("L", (100, 100), 235)
    ImageDraw.Draw(img).rectangle((10, 10, 60, 60), fill=30)
    t = ocr_mod.otsu_threshold(img)
    assert 30 <= t < 235
    out = ocr_mod._binarize(img)
    assert out.getpixel((20, 20)) == 0 and out.getpixel((90, 90)) == 255


def test_upscale_only_grows_small_images_and_caps_the_scale():
    small = Image.new("RGB", (400, 800), "white")
    assert ocr_mod._upscale(small).width == 1500
    already_big = Image.new("RGB", (1600, 800), "white")
    assert ocr_mod._upscale(already_big).size == (1600, 800)
    tiny = Image.new("RGB", (100, 100), "white")
    assert ocr_mod._upscale(tiny).width == 400  # capped at 4x


def test_darkest_channel_keeps_pink_print_dark():
    pink = Image.new("RGB", (4, 4), (220, 60, 140))
    assert ocr_mod._darkest_channel(pink).getpixel((0, 0)) == 60
    assert ocr_mod._gray(pink).getpixel((0, 0)) > 100  # plain greyscale washes it out


FONT_CANDIDATES = [
    "/System/Library/Fonts/Menlo.ttc",                              # macOS
    "/System/Library/Fonts/Monaco.ttf",                             # macOS
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",          # Linux
    "C:/Windows/Fonts/consola.ttf",                                 # Windows
]


def _readable_font():
    """A real monospace font at a legible size. Pillow's built-in default font is tiny, and tiny
    text is a different (and much harder) problem than the one this test is about."""
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            return ImageFont.truetype(path, 28)
    pytest.skip("no suitable font found on this machine")


@needs_tesseract
def test_ocr_reads_a_clean_generated_receipt_with_every_variant(tmp_path):
    font = _readable_font()
    img = Image.new("RGB", (800, 200), "white")
    d = ImageDraw.Draw(img)
    d.text((20, 25), "ACME TRADING SDN BHD", font=font, fill="black")
    d.text((20, 100), "TOTAL 123.45", font=font, fill="black")
    path = tmp_path / "r.png"
    img.save(path)
    for name in ["raw", "up_psm6", "up_min_psm6", "otsu_psm6"]:
        text = ocr_mod.ocr(str(path), name)
        assert "123.45" in text, f"{name} lost the total: {text!r}"
