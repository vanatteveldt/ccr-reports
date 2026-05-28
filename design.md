# CCR Journal Health Report — Design

A repeatable overview of the editorial health of *Computational Communication
Research* (CCR), delivered as a Quarto document. This file defines **what we want
to answer, what data we have, what is missing, and how each metric is derived** —
before any implementation.

Status: design draft. No code written yet.

---

## 1. Goal & scope

Produce a re-runnable report (`health-report.qmd`) that, from a fresh set of OJS
exports (and/or API pulls), summarizes:

1. **Submissions & decisions over time** — pipeline volume, outcomes, throughput.
2. **Author diversity** — geography, affiliation, gender (inferred), and topics.
3. **Associate Editor (AE) load & speed** — submissions handled per editor and
   time-to-decision.
4. **Top authors** — most prolific / most published contributors.
5. **Top reviewers + reliability** — most active reviewers, and those who declined
   or never responded ("ghosted").

Design principle: **reproducibility**. Re-running with a newer export (or live API
pull) should regenerate the whole report. We prefer the API for inputs we can fetch
programmatically, falling back to manual CSV exports where the API does not expose
the data.

---

## 2. Data sources we currently have

All under `reports/`, exported 2025-12-03 from `journal.computationalcommunication.org`
(OJS, hosted by HOPE / UZH). ISSN 2665-9085.

### 2.1 `articles-CCR-20251203.csv` — submissions (grain: 1 row per submission)
- **Count:** 452 rows; submitted 2018-10-24 → 2025-12-01.
- **Identity:** `Submission ID`, `Title`, `Abstract`, `URL`, `DOI`.
- **Authors (wide, up to 10):** per author — Given/Family Name, ORCID, **Country**,
  **Affiliation**, Email, Homepage, Bio.
- **Classification:** `Section title` (Research Article, Research Note, Tool
  Announcement, and Special Issues), `Keywords`, `Subjects`, `Disciplines`,
  `Language`.
- **Lifecycle:** `Status` ∈ {Declined 256, Published 96, Review 61, Submission 33,
  Copyediting 6}; `Date submitted`, `Last modified`, `First published`.
- **Editors & decisions (wide, up to 7 editors × 6 decisions each):** per editor —
  Given/Family Name, ORCID, Email, then `Editor Decision 1..6` + `Date decided 1..6`.
  - Decision vocabulary observed: `Decline Submission` (118), `Send for Review`
    (88), `Resubmit for Review` (46), `Accept Submission` (17), `Request Revisions`
    (13), `Send To Production` (5).

### 2.2 `reviews-20251203.csv` — review assignments (grain: 1 row per reviewer×assignment)
- **Count:** 422 rows; 279 distinct reviewer emails; all `Stage = Review`.
- **Keys:** `Submission ID`, `Submission Title` (⚠ contains raw `<b>` HTML), `Round`.
- **Reviewer:** username, Given/Family Name, ORCID, Country, Affiliation, Email,
  `Reviewing interests`.
- **Timeline:** `Date Assigned`, `Date Notified`, `Date Confirmed`,
  `Date Completed`, `Date Acknowledged`, `Date Reminded`,
  `Response Due Date` / `Response Overdue Days`, `Review Due Date` /
  `Review Overdue Days`.
- **Outcome:** `Declined` (Yes 66 / No 356), `Cancelled` (Yes 6 / No 416),
  `Consideration` (Considered 74 / Never 348), `Recommendation`
  (blank 186, Revisions Required 100, Resubmit for Review 42, Decline 40,
  Accept 40, Resubmit Elsewhere 7, See Comments 7).
- **Completed reviews:** 236.

### 2.3 `user-report-2025-12-03.csv` — registered users (grain: 1 row per user)
- **Count:** 841 users. ID, name, email, phone, **Country**, mailing address,
  `Date registered`.
- **Role flags (Yes/No):** Journal manager, **Journal editor (9)**,
  Production editor, **Section editor (0)**, **Guest editor (12)**, Copyeditor,
  …, **Reviewer (638)**, **Author (331)**, Reader, etc.
- ⚠ `Section editor = 0`: AE handling cannot be derived from role flags here — it
  must come from the editor columns in the articles export (see §5.3).

### 2.4 COUNTER usage XML (`counter-4.1-AR1-*.xml`, `counter-4.1-JR1-*.xml`)
- **JR1:** monthly journal-level full-text PDF requests (`ft_pdf`).
- **AR1:** monthly per-article full-text requests (`ft_total`), keyed by DOI +
  article title.
- Months present so far: 2025-05 → 2025-12. Useful as a readership/impact signal.

---

## 3. The OJS REST API — **probed live and confirmed (OJS 3.4)**

Base URL: `https://journal.computationalcommunication.org/api/v1/`. Auth:
`?apiToken=<token>` query param (the install rejects all unauthenticated requests,
incl. `/issues`). Token lives in `./.env` as `OJS_ADMIN_TOKEN` (admin scope,
`contextId = 22`). **This token is a secret — load from `.env`, never hardcode or
print it.** Docs: <https://docs.pkp.sfu.ca/dev/api/ojs/3.4>.

The API is the **preferred, fully-scriptable input** and in several places is
*richer* than the CSV exports. Verified responses:

| Endpoint | Returns (confirmed) | Use for |
|---|---|---|
| `/submissions` | 505 items; per-submission `status/statusLabel`, `stageId`, `stages`, `dateSubmitted`, `lastModified`, `dateLastActivity`, `submissionProgress`, embedded `publications`, `reviewRounds`, `reviewAssignments` | §5.1 pipeline, §5.4 authors |
| `/submissions/{id}/decisions` | **editorial decision log**: `dateDecided`, `decision` (code) + `label` (e.g. "Send for Review"), **`editorId`**, `stageId`, `reviewRoundId` | §5.1 funnel, **§5.3 AE speed/load** |
| `/submissions/{id}` → `reviewAssignments[]` | per-assignment `round`, `roundId`, `due`, `responseDue`, `statusId` + human `status` (e.g. *"The reviewer has missed the response due date"*, declined, complete) | §5.5 review **status** counts |
| `/submissions/{id}/publications` / `.../publications/{id}` | publication metadata + `authors[]` (name, affiliation, country, ORCID), DOIs, keywords | §5.2, §5.4 |
| `/stats/editorial` | **decision funnel, supports `dateStart`/`dateEnd`**: received 498, accepted 53, declined 197 (desk-reject 163, post-review 34), published 109, in-progress 7 | §5.1 |
| `/stats/editorial/averages` | per-year averages of the above | §5.1 context |
| `/stats/publications` | per-article `abstractViews`, `galleyViews`, `pdfViews`, `htmlViews` (richer & more current than COUNTER XML) | §7 readership |
| `/stats/users` | role counts incl. **Section Editor = 18**, Reviewer, Author = 376 | §5.3 AE roster |
| `/users` | 964 users with `groups[]` (role objects) | identity / roles |
| `/issues` | published issues, `datePublished` | §7 |

**Two key wins over the CSV exports:**
- **AE attribution is solved.** Each decision carries `editorId` + `dateDecided`,
  so "who decided what, when" is unambiguous — no more guessing the handling editor
  from role-less editor columns (§5.3). Map `editorId` → name via `/users/{id}`;
  AE = Section Editor role.
- **Editorial funnel & usage are first-class** via `/stats/editorial` (date-ranged)
  and `/stats/publications`.

**The one gap — reviewer identity.** The `reviewAssignments` returned by the
submission endpoint give assignment **status and due dates but NOT the reviewer's
name/email/userId** (appears anonymized in this view; no decline/complete dates
either). So per-reviewer "top reviewers / who ghosted or declined" (§5.5) is **not
cleanly answerable from the API as probed** — the `reviews-*.csv` export remains the
reliable source there (it has reviewer name, email, ORCID, and full assign→
confirm→complete timeline). To verify: whether an editor-context call or a different
parameter exposes `reviewerId`; if not, CSV stays in the loop for §5.5.

**Counts differ by design:** API `/submissions` = 505 and `/stats/editorial`
received = 498 vs CSV 452, because the API includes incomplete/in-progress drafts
(and a same-day test submission). Filter on `status`/`submissionProgress` for
comparability.

**Proposed stance:** **API-first.** Drive §5.1–5.4 and §7 from the API (one script,
no manual download). Keep a single manual CSV export (`reviews-*.csv`) **only** for
§5.5 reviewer-level reliability, unless API reviewer identity is confirmed.

---

## 4. Cross-cutting data-quality issues

These shape every downstream metric and must be handled centrally:

1. **Wide → long reshaping.** Authors (×10) and editors (×7, each ×6 decisions) are
   in wide columns. Both need pivoting to long tables (`submission_authors`,
   `submission_decisions`).
2. **Snapshot, not history.** Each export is a point-in-time snapshot. "Over time"
   trends rely on **decision/submission dates within** the file, not on diffing
   snapshots. Worth archiving each dated export under `reports/` for an audit trail.
3. **Identity resolution.** Resolve people by **ORCID → email → normalized name**
   (many ORCIDs are blank). Needed to dedupe top authors/reviewers and to link a
   reviewer/editor across submissions.
4. **HTML in text fields.** Strip tags (e.g. `<b>`) from titles before display.
5. **Missing values.** Country/affiliation absent for many authors; ORCID often
   blank. Report coverage (% non-missing) alongside diversity breakdowns.
6. **Gender — omitted (decided).** Not in the data and inference from first names is
   error-prone, so the report excludes gender for now. Can be added later if wanted.
7. **Editor role ambiguity.** The articles export lists multiple editors per
   submission without a role label (handling AE vs EiC vs guest vs editorial-office
   account, e.g. `ccreditorialteam@gmail.com`). See §5.3.

---

## 5. Question-by-question mapping

For each: source → key fields → derived metrics → gaps.

### 5.1 Submissions & decisions over time
- **Source:** articles CSV.
- **Fields:** `Date submitted`, `First published`, `Status`, `Section title`,
  `Editor Decision N` + `Date decided N`.
- **Metrics:**
  - Submissions per quarter/year (by `Date submitted`), split by section / special
    issue.
  - Outcome funnel: submitted → sent for review → revisions → accepted/declined →
    published, using the decision vocabulary in §2.1.
  - Acceptance & desk-reject rate over time (desk-reject ≈ `Decline Submission`
    with no preceding `Send for Review`).
  - Publications per year and time-to-publish (`First published` − `Date submitted`).
- **Gaps:** "in flight" submissions have no terminal decision yet (Status Review/
  Submission) — exclude from outcome rates or show as a separate "pending" band.

### 5.2 Author diversity (and topics)
- **Source:** articles CSV (author block), enriched.
- **Metrics:**
  - **Geography:** distribution of author countries, reported in **two separate
    tables — first author and all co-authors** (consistent with §5.4).
  - **Affiliation/institution** concentration (top institutions); needs light
    normalization ("University of X" variants).
  - **Gender:** omitted (see §4.6).
  - **Topics:** keyword frequency / co-occurrence; section & special-issue mix as a
    coarse topical signal. Optional later: cluster abstracts.
- **Gaps:** missing country/affiliation; free-text keywords need normalization.

### 5.3 Associate Editor load & decision speed
**Two distinct signals, do not conflate them:**
- **Assigned editor** (who is *responsible* for a submission) → from
  **`/submissions?assignedTo=<editorId>`** (reverse-lookup filter; confirmed
  working). This is the basis for **AE load**.
- **Deciding editor** (`editorId` on `/submissions/{id}/decisions`, who *clicked*
  a decision, with `dateDecided`) → basis for **AE speed / timestamps**.

- **Role mapping = `editors.csv`** (repo root), from the EiC's roster, confirmed
  against the API. Source of truth — OJS role *names* mislead here: CCR's AEs all
  carry the **"Journal editor"** group (not "Section Editor"), plus duplicate/test
  accounts to exclude.
  - **EiC:** Wouter van Atteveldt (20275).
  - **AEs:** Damian Trilling (19420), Emese Domahidi (18291), Rene Weber (20815),
    Kokil Jaidka (18280). **Past AEs:** Drew Margolin (20656), Cuihua "Cindy" Shen
    (20751).
  - **Assistant editor:** Rupert Kiddle (20594) — assignment + production.
  - **Code editor:** Chung-hong Chan (20474) — reproducibility / tool edits.
  - **Guest editors:** ~12, per special issue ("Guest editor" group) — label by issue.

- **Who actually clicks what (empirical, all 610 decisions, decision × role):**
  - *Substantive review decisions* (`Send for Review`, `Resubmit for Review`,
    `Accept`, `Request Revisions`) are spread across **AEs, EiC, and guest editors**
    (the large "other/guest" column = guest editorial teams handling special issues
    — legitimate handling editors, not noise).
  - **`Send To Production`**: ~all (38/39) clicked by the **assistant editor
    (Rupert)** — he's assigned production at the end of most articles. Expected.
  - **`Decline Submission`**: ~124 of ~209 clicked by **Rupert** — these are
    **desk rejects** (declined at the *submission* stage, **before any AE is
    assigned**), executed by the editorial office on the EiC's behalf. They
    correctly have **no handling AE**. Post-review declines (the AE-involved ones)
    are the smaller group. ⚠ So the deciding `editorId` still must NOT drive AE
    counts, and desk-rejects must be excluded from AE load (no AE existed).
  - **Separating desk-reject vs post-review decline:** by the decline decision's
    `stageId` (1 = submission/desk-reject, 3 = review) — consistent with
    `/stats/editorial`'s split (desk-reject 163 / after-review 34).

- **Assigned-submission counts** (`assignedTo`, current snapshot): Damian 27,
  Wouter/EiC 25, Rene 16, Emese 14, Kokil 14, Rupert 112 (production on most papers).

- **Metrics:**
  - **AE load:** submissions where the AE is the **assigned** handling editor
    (`assignedTo`), split by section/status; exclude Rupert's production-only
    assignments (his count is inflated by the production role).
  - **AE speed:** per assigned submission, time from `dateSubmitted` (and from the
    `Send for Review` date, for review-stage turnaround) to the relevant decision
    `dateDecided`, attributed to the **assigned AE** — *not* the clicker.
  - Report EiC, assistant, code editor, and guest teams separately from AEs.
- **Open:** distinguishing an AE's *handling* assignment from a mere
  *production/co-assignment* (e.g. Rupert, or EiC oversight). May need the
  per-submission participant/role detail — verify whether `assignedTo` results can
  be qualified by stage/role, or fall back to the articles CSV editor columns.
- **CSV fallback:** articles CSV editor columns + `Date decided N` (role-less, needs
  `editors.csv`) if not using the API.

### 5.4 Top authors
- **Source:** API publications `authors[]` (or articles CSV author block,
  long-reshaped), with §3 identity resolution.
- **Metrics:** **two separate ranking tables (decided):**
  - **First author** — ranked by submissions and by published articles.
  - **All co-authors** — same, crediting every author position.

  Optionally: repeat-author retention over years.
- **Gaps:** name disambiguation without ORCID (watch the duplicate accounts noted in
  §5.3, e.g. authors with multiple OJS user records).

### 5.5 Top reviewers & reliability (declined / ghosted)
- **Source: `reviews-*.csv`** (with §3 identity resolution). The API exposes review
  assignment *status* but **not reviewer identity** (see §3), so per-reviewer
  naming needs the CSV. This is the one section that keeps a manual export.
- **Metrics (per reviewer):**
  - **Activity:** # assignments, # completed reviews, # rounds.
  - **Reliability buckets** per assignment:
    - *Completed* — `Date Completed` present.
    - *Declined* — `Declined = Yes` (66).
    - *Cancelled* — `Cancelled = Yes` (6).
    - *Ghosted / no response* — not declined, not cancelled, never confirmed/
      considered, no completion (~114–120 candidates). **Caveat:** exclude
      still-open recent assignments (review window not yet elapsed) so we don't
      label active reviewers as ghosts — use `Review Due Date` vs report date.
  - **Timeliness:** mean response lag (`Date Confirmed` − `Date Assigned`), mean
    review turnaround (`Date Completed` − `Date Confirmed`), overdue days.
  - **Recommendation mix** per reviewer (optional).
- **Gaps:** "ghost" is inferred, not a flag — definition above must be stated in the
  report; reviewer pool (638 with role) ≫ actually-assigned (279), so "top reviewer"
  is relative to those ever assigned.

---

## 6. Proposed report structure (`health-report.qmd`)

1. **Header / KPIs** — totals: submissions, published, acceptance rate, median
   time-to-decision, active reviewers, full-text downloads (last 12 mo).
2. **Submissions & decisions over time** (§5.1) — time series + funnel.
3. **Author diversity & topics** (§5.2).
4. **Associate Editors** (§5.3) — load and speed tables/plots.
5. **Top authors** (§5.4).
6. **Reviewers & reliability** (§5.5).
7. **Readership** — COUNTER usage trend, top-downloaded articles.
8. **Appendix** — data sources, export date, definitions, coverage/missingness,
   caveats (gender inference, ghost definition, editor-role mapping).

**Implementation notes (for later):** R + Quarto (project is already an RStudio
`.Rproj`); a small `R/load.R` doing the wide→long reshaping and identity resolution
once, reused by all sections; parameterize the export date / API toggle via Quarto
params so re-running on fresh data is one step.

---

## 7. What we can answer well today vs. what needs a decision

**Answerable now from existing exports:** submission/decision trends, acceptance &
turnaround, author geography & affiliation, topics (keywords/sections), top authors,
reviewer activity & reliability, usage trends.

**Resolved by the API probe (was uncertain in v1 of this doc):**
- OJS version = **3.4**; token works (admin, contextId 22).
- Editorial funnel, decision history *with editor + date*, usage stats, and roles
  are all available via the API → §5.1–5.4 and §7 can be fully automated.
- AE attribution via `editorId` on decisions (§5.3).

**Decided:**
- Gender: **omitted** (§4.6).
- Author credit: **two separate tables** — first author and all co-authors —
  for both diversity (§5.2) and top authors (§5.4).

**Still needs verification (not a user decision):**
- Reviewer identity is not in the API as probed → §5.5 keeps a manual `reviews.csv`
  export (or confirm an editor-scoped API call exposes `reviewerId`).
- Whether `assignedTo` can be qualified by stage/role to separate an AE's handling
  assignment from production/oversight co-assignment (§5.3).

---

## 8. Open questions for the journal team

1. ~~**AEs:** identify handling editors and exclude office accounts.~~
   **RESOLVED** — roster captured in `editors.csv` (EiC, 4 current AEs, 2 past AEs,
   assistant + code editor, guest editors by issue). Attribution = deciding
   `editorId` on substantive decisions; procedural decisions are the assistant
   editor's. Open sub-point: enumerate guest editors per special issue when needed.
2. **API reviewer identity:** confirmed the API gives decisions + editorIds + usage,
   but review assignments are anonymized (no reviewer name). Is there an
   editor-scoped call that exposes `reviewerId`? If not, §5.5 stays on the CSV.
3. **Gender:** do you want an inferred-gender diversity view (with caveats), or omit
   it?
4. **Reporting period & cadence:** rolling all-time, per-year, or trailing 12 months?
   How often will this be regenerated (quarterly)?
5. **"Ghosted" definition:** confirm the rule in §5.5 (never-responded, window
   elapsed) matches how the team thinks about non-responsive reviewers.
6. **Author credit:** count all co-authors or first/corresponding only for "top
   authors" and diversity?
