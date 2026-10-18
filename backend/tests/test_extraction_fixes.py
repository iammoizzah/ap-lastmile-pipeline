"""
Regression tests for extraction fixes, using receipt-shaped text taken from real
SROIE failures. These run against the real parser (not a stub), so they fail if
scripts/apply_fixes.py has not been run yet. That is intended.
"""
import pytest

from app.services.extraction import extract_fields


def total_of(text):
    return extract_fields(text).total


def company_of(text):
    return extract_fields(text).company.value


# Receipts have a correct "TOTAL : x" line followed by "CASH : x", and a duplicate
# tax-summary row at the bottom ("TOTAL: subtotal tax") that used to win.
@pytest.mark.parametrize("text,expected", [
    ("SUB-TOTAL (BX) : 25.80\nTOTAL TAX : 4.85\nROUNDING : 0.00\nTOTAL : 27.35\n"
     "CASH : 27.35\nCHANGE ; 0.00\nTOTAL: 25.80 1.55", "27.35"),
    ("Total Qty.: 8 120.00\nSUB-TOTAL (EX) : 120.00\nTOTAL TAX 7.20\nROUNDING : 0.00\n"
     "TOTAL : 127.20\nCASH : 127.20\nCHANGE : 0.00\nTOTAL; 120.00 7.20", "127.20"),
    ("Total Qty. : 2 1.00\nSUB-TOTAL (EX) : 1.00\nTOTAL TAX : 0.06\nROUNDING : -0.01\n"
     "TOTAL : 1.05\nCASH 1.05\nCHANGE 0.00\nTOTAL: 1.00 0.06", "1.05"),
])
def test_total_confirmed_by_matching_cash_line(text, expected):
    t = total_of(text)
    assert t.value == expected
    assert t.confidence >= 0.95


def test_gst_amount_line_with_rate_is_not_the_total():
    t = total_of("TakeOut Total (incl GST) 38.90\nTotal Rounded 38.90\nCash Tendered 50.00\n"
                 "Change 11.10\nTOTAL INCLUDES 6% GST 2.20")
    assert t.value == "38.90"


def test_tax_only_lines_are_skipped_in_favour_of_the_real_total():
    assert total_of("Total GST @6%: 0.00\nTotal Inclusive GST: 193.00").value == "193.00"
    assert total_of("(Excluded GST) Sub Total (RM) 411.50\nTotal GST (RM) 24.89\n"
                    "Total (RM): 436.20").value == "436.20"


def test_amount_on_the_line_after_the_label():
    assert total_of("Total RM inc.GST:\n4.90").value == "4.90"


def test_garbled_receipt_falls_back_with_low_confidence():
    t = total_of("KO13 180\n23.03\n1296652800\n0.94\n0.06")
    assert t.confidence <= 0.5  # the system must admit it is guessing


def test_company_skips_copy_banner_and_cashier_name():
    assert company_of("TAN CHAY YEE\n*** COPY ***\nOJC MARKETING SDN BHD\nROC NO: 538358-H") \
        == "OJC MARKETING SDN BHD"


def test_company_rejects_banners_bare_suffixes_and_addresses():
    # real failures from the first 40-receipt run: vendor came out as these lines
    assert company_of("ART TAX INVOICE\nSDN BHD\n47, JALAN MERANTI 1, SEK. 3,\n44300 BATANG KALI") is None
    assert company_of("* TAX INVOICE *\nNO. 53, JALAN BESAR,\n+60 3 1234 5678") is None


def test_company_names_that_start_with_digits_still_work():
    assert company_of("99 SPEED MART S/B (519537-X)\nLOT 12 JALAN BESAR") == "99 SPEED MART S/B (519537-X)"


def test_clean_receipt_end_to_end():
    r = extract_fields("OJC MARKETING SDN BHD\nDATE : 15/01/2019 11:05:16 AM\nTotal Inclusive GST: 193.00")
    assert (r.company.value, r.date.value, r.total.value) == ("OJC MARKETING SDN BHD", "15/01/2019", "193.00")
    assert r.overall_confidence >= 0.85


def test_company_name_containing_a_place_word_is_still_a_company():
    # real SROIE receipt: "TAMAN" is part of the branch name, not an address line
    text = "BOOK TA .K (TAMAN DAYA) SDN BHD\nNO.53 55,57 & 59, JALAN SAGU 18, TAMAN DAYA,\n81100 JOHOR BAHRU"
    assert company_of(text) == "BOOK TA .K (TAMAN DAYA) SDN BHD"
