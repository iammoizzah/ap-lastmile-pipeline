# Evaluation

This document reports how well the pipeline works, how the numbers were produced, and where they should not be trusted.

## Method

**Data.** SROIE receipts (ICDAR 2019), real scanned receipts with ground-truth company, date, address and total. Two disjoint sets of 100:

- **Development set** (SROIE `test` split): used while building. Failures on these receipts guided changes to the extractor, so results here are optimistic.
- **Held-out set** (SROIE `train` split): never inspected. The extractor and matcher were frozen at commit `fbd4bdd` before this set was run, and nothing was changed afterwards.

**Reference data.** SROIE has no purchase-order system, so vendors and POs are generated from each receipt's ground truth by `scripts/seed_po_from_sroie.py`, with deliberate problem scenarios mixed in:

| Scenario | Held-out set |
|---|---|
| Vendor unknown (nothing seeded) | 19 |
| Vendor known, no PO | 8 |
| PO amount 8% off the true total | 15 |
| Clean PO | 57 |
| Skipped (unusable ground truth) | 1 |

**Definitions.**

- A receipt is **correct** when the extracted vendor and total both match ground truth (vendor by fuzzy name match ignoring legal suffixes, total by exact amount).
- **Route** is the system's decision: `fast_track` (no flags, high extraction and match confidence) or `review`.
- **Baseline** is the naive alternative: skip review whenever extraction confidence is at least 0.85, with no cross-check.

Commands to reproduce are at the end.

## Results

### Extraction alone

| | Development | Held-out |
|---|---|---|
| Company | not recorded | 59% |
| Date | not recorded | 69% |
| Total | 63% | 47% |
| Overall (3 fields) | not recorded | 58.3% |
| Vendor and total both correct | 55% | 44% |
| Receipts below 0.7 confidence that had a wrong field | not recorded for the final extractor (21 of 21 on an earlier version) | 26 of 26 |

Total accuracy fell from 63% to 47% between the development and held-out sets. The gap is the cost of tuning on a small set, and the held-out figure is the honest estimate.

### Whole system versus confidence-only routing

| | Development | Held-out |
|---|---|---|
| Invoices with a wrong vendor or total | 45 | 56 |
| Fast-tracked | 11 | 12 |
| Wrong among fast-tracked | 1 | 1 |
| Sent to human review | 89 | 88 |
| **Wrong invoices caught (system)** | **44 of 45 (97.8%)** | **55 of 56 (98.2%)** |
| Wrong invoices caught (confidence-only baseline) | 34 of 45 (75.6%) | 38 of 56 (67.9%) |
| Reviews the baseline would have done | 67 | 53 |
| Extra reviews per extra error caught | 2.2 | 2.1 |

With 56 wrong invoices, the 95% interval for the system's catch rate is roughly 91% to 100%, and for the baseline roughly 55% to 79%.

### Where the review load comes from

| Reviews | Development | Held-out |
|---|---|---|
| Total sent to review | 89 | 88 |
| Invoices that really were wrong | 44 | 55 |
| Correctly extracted, but disagree with the PO or vendor master | 20 | 16 |
| Correctly extracted, reviewed for reasons unrelated to the PO data | 25 (28%) | 17 (19%) |

The PO disagreements are largely by construction: 42% of the held-out receipts were seeded as unknown-vendor, no-PO or amount-mismatch scenarios, and a human should look at an invoice that disagrees with its PO. The last row is the avoidable load. Its reasons, counted per receipt (a receipt can have more than one):

| Reason | Development | Held-out |
|---|---|---|
| Extractor uncertainty (low confidence or a missing field) | 8 | 7 |
| Possible duplicate (same vendor and total, different date) | 4 | 6 |
| No flag, but below the fast-track confidence bar | 15 | 6 |

The duplicate rule fires on ordinary repeat retail purchases and is a candidate for tightening. It was not changed after the held-out run, because that would contaminate the result.

## What this shows

1. **Extraction alone is not safe to automate.** On unseen receipts it gets the vendor or total wrong more than half the time.
2. **A second source of truth catches what the extractor cannot.** The extractor reports high confidence on many wrong totals. Comparing against the vendor master and purchase orders caught nearly all of them, and that held up on unseen data. As the extractor got worse (55% to 44% correct), the baseline got worse (76% to 68%) while the system stayed at about 98%.
3. **The safety has a price.** About two additional human reviews are needed for each additional error caught, and roughly 88% of invoices still go to a person. This is a safety result, not an automation-rate result. Of the 88 held-out reviews, 55 were for invoices that really were wrong, 16 for correct extractions that disagree with the reference data, and 17 (19%) for reasons unrelated to the PO data.
4. **Tuning on a small set overstates accuracy.** Reported honestly, the extractor's total accuracy is 47%, not 63%.

## Limitations

- **The PO data is generated from the ground truth.** The PO check has an easier job here than it would against a real ERP, where an invoice legitimately differs from its PO for many reasons. The catch rate is a demonstration of the mechanism, not a prediction of production performance.
- **Part of the review load is by construction.** About 42% of the held-out receipts were seeded as scenarios the PO check is supposed to object to (unknown vendor, no PO, amount mismatch). An invoice that was extracted correctly but disagrees with its PO is correctly sent to a reviewer, even though the evaluation counts it as a "false alarm". Of the 33 held-out receipts that were extracted correctly but sent to review, 16 had a PO or vendor-master disagreement, so they are justified given the reference data (see the table above).
- **Small samples.** 56 wrong invoices support the intervals above and no finer claim.
- **Printed rounding adjustments.** Some receipts print a rounding line (for example total 23.79, rounding +0.01, amount paid 23.80). Ground truth records the rounded amount, the extractor reads the printed total, and the two differ by a sen. This affected 2 of 100 development receipts. The one wrong invoice that reached fast-track on the development set was one of these. Held-out fast-track escape: [fill in after inspecting it]. The reconciliation matcher tolerates differences of this size.
- **OCR quality is a ceiling.** Many remaining total errors come from receipts where Tesseract's output is garbled. No parser fixes that, which is why uncertain invoices go to a human.
- **Development company, date and overall accuracy were not recorded** after the final extractor changes, so only the held-out figures are reported for those.

## Reproducing

```bash
docker compose up -d
cd backend
python3 -m pip install -r requirements.txt
python3 scripts/init_db.py && python3 scripts/seed.py

python3 scripts/download_sroie.py --n 100 --split train      # held-out set
python3 scripts/seed_po_from_sroie.py
python3 scripts/eval_extraction.py

uvicorn app.main:app --reload                                 # in a second terminal
python3 scripts/eval_pipeline.py --n 100                      # needs an empty invoices table
```

For the development set use `--split test`. Clear invoices between runs with:

```sql
TRUNCATE review_decisions, expected_payments, invoices, audit_log CASCADE;
```
