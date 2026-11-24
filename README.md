# Introduction to Spatial Data Science (GEOG 215)

A working-draft textbook for **GEOG 215, Introduction to Spatial Data Science**, at UNC-Chapel Hill,
written by David Parr from the course lectures. It is a [Quarto](https://quarto.org) book: every
chapter is a runnable document, so the tables, maps and figures come from the R code printed beside
them.

The book is published in two places from this repo:

| Site | Who can read it | Built by |
|---|---|---|
| **https://geog215.org** | Students on the class roster, after signing in with an emailed code. Their progress is recorded for the instructor. | Cloudflare Workers Builds (`wrangler.jsonc`, `scripts/cloudflare-build.sh`) |
| **https://daveparr.com/geog215/** | Anyone. No sign-in, and nothing is recorded. | GitHub Action (`.github/workflows/publish.yml`), which commits the rendered book into the `daveparr.com` repo |

Both rebuild automatically on every push to `main`.

## Site layout

Every page has a top menu: **Welcome**, **Syllabus**, **Textbook**, **Course materials**, and
**About**. In the sidebar these are two parts, *Course* and *Textbook*.

| Page | File | Sign-in on geog215.org |
|---|---|---|
| Welcome (home page) | `index.qmd` | Public |
| Syllabus | `syllabus.qmd` | Public |
| AI policy (linked from the syllabus) | `ai-policy.qmd` | Public |
| Course materials: staff and office hours, schedule, deadlines | `materials.qmd` | Students only |
| About the author | `about.qmd` | Public |
| Privacy policy (linked from the sign-in screen and page footer) | `privacy.qmd` | Public |
| Textbook: preface, chapters, chapter quizzes, glossary | `preface.qmd`, `chapters/`, `glossary.qmd` | Students only |

The public pages are listed in `PUBLIC_PAGES` in `assets/auth-gate.html`; keep that list in step with
the menu in `_quarto-site.yml`. The course pages are copied from the Fall 2026 Course Resources doc in
Google Drive, so update them each semester.

daveparr.com/geog215/ gets **only the textbook**: the chapters, chapter quizzes, and glossary, with
the Preface as its home page and no top menu. The `textbook` profile (`_quarto-textbook.yml`) lists
those chapters, and `_quarto-site.yml` lists the full site; one of the two is always active, and
`site` is the default. A new chapter goes in both files.

## What's in the book

| Chapter | Quiz bank |
|---|---|
| What is Spatial Data Science? | 28 questions |
| R, RStudio, and R Markdown | 27 questions |
| R Basics | 30 questions |
| Indexing Vectors and Data Frames | 30 questions |
| Into the Tidyverse: glimpse, filter, and the Pipe | 29 questions |
| Into the Tidyverse: arrange, distinct, select, and mutate | 30 questions |
| Into the Tidyverse: summarize, group_by, and drop_na | 28 questions |
| Census Data and APIs | 32 questions |

Each chapter is followed by a **chapter quiz** page. Readers also get:

- **Runnable R in the browser.** Code cells use [webR](https://docs.r-wasm.org/webr/) through the
  `coatless/webr` Quarto extension, so students can edit and run R without installing anything.
- **Hover definitions for key terms.** About 130 key terms (spatial autocorrelation, MAUP, GEOID,
  margin of error, knit, pipe, ...) are defined once in `glossary.yml`. In the chapters, the first
  use of each term in a section gets a dotted underline and shows its definition on hover, tap, or
  keyboard focus (`filters/glossary/`). The same file builds the **Glossary** page at the back of
  the book. To add or edit a term, edit `glossary.yml`; no chapter changes are needed.
- **Self-check questions** inside chapters, from the
  [webexercises](https://psyteachr.github.io/webexercises/) R package.
- **Duolingo-style chapter quizzes** (`assets/quiz/`). Each quiz draws 10 random questions from the
  chapter's bank in `quizzes/`: multiple choice, true/false, fill in the blank, put the tiles in
  order, and write R code that is checked by running it with webR. Missed questions come back at the
  end until every one is right. A cartoon of the instructor cheers on right answers, looks sad at
  wrong ones, and appears on the end-of-quiz screen with confetti. Right answers play a happy chime
  and wrong ones a buzzer (made with the Web Audio API; a speaker button turns sound off).

## How the site works

- **Rendering.** `_quarto.yml` defines the book. `freeze: auto` stores each chapter's code results in
  `_freeze/`, which is committed, so the GitHub Action and Cloudflare can render the book without
  installing R. Re-render a chapter locally (with R) whenever you change its code, and commit the
  updated `_freeze/` files.
- **geog215.org profile.** `quarto render --profile geog215` (`_quarto-geog215.yml`) adds the sign-in
  gate (`assets/auth-gate.html`) and Google Analytics. The publish Action builds daveparr.com with
  `--profile textbook` (textbook only), which has neither.
- **Sign-in and progress.** [Supabase](https://supabase.com) holds the class roster and progress.
  Students type their email and receive a one-time code or link, sent through Resend from
  `mail.geog215.org`. Only roster and instructor emails can sign in. The gate records pages opened,
  self-check answers, webR code runs and chapter quiz answers.
- **Admin page.** https://geog215.org/admin/ (`admin/index.html`) lets instructors add and lock out
  students and see progress by student, page, self-check, code cell and chapter quiz. It is copied
  only into the geog215.org build, never the public copy.

See `supabase/README.md` for the one-time setup, the admin page and troubleshooting, and
`quizzes/README.md` for how to write a quiz bank.

## Repository layout

| Path | Contents |
|---|---|
| `index.qmd`, `syllabus.qmd`, `materials.qmd`, `about.qmd` | Course pages (Welcome, Syllabus, Course materials, About) |
| `preface.qmd` | Textbook preface |
| `chapters/` | One `.qmd` per chapter, plus its `-quiz.qmd` page |
| `quizzes/` | Chapter quiz question banks (JSON) and how to write them |
| `assets/quiz/` | The quiz engine (`quiz.js`, `quiz.css`), including the instructor cartoon |
| `assets/auth-gate.html` | The geog215.org sign-in screen and progress tracking |
| `admin/` | The instructor admin page |
| `supabase/` | Database setup (`setup.sql`) and setup guide |
| `data/`, `data-raw/` | Data used in chapters, and the scripts that build it |
| `images/` | Figures and screenshots |
| `glossary.yml`, `glossary.qmd` | Key terms and definitions, and the Glossary page built from them |
| `filters/glossary/` | Lua filter, script, and styles for the hover definitions |
| `include/` | webexercises CSS and JS |
| `_extensions/` | Quarto extensions (webR) |
| `_templates/` | PrettyPDF template for the PDF format |
| `_freeze/` | Stored code results (committed on purpose) |
| `scripts/cloudflare-build.sh` | Cloudflare build: installs Quarto and renders the gated book |

## Working on the book

```sh
quarto preview                      # full site without the sign-in gate, live reload
quarto render --profile geog215     # geog215.org version, with the sign-in gate
quarto preview --profile textbook   # daveparr.com version: textbook only (the Action also
                                    # copies preface.qmd over index.qmd first)
```

Chapters use `tidyverse`, `sf`, `tigris`, `tidycensus`, `tmap`, `httr2` and `webexercises`. The
Census chapter needs a free Census API key (see the Preface); chunks that call the API are skipped
when no key is set.

To add a chapter, add its `.qmd` to `chapters/` and to both `_quarto-site.yml` and `_quarto-textbook.yml`, then add its quiz by following
`quizzes/README.md`. Changes go through a pull request into `main`; Cloudflare builds a preview of
each branch, and merging publishes both sites.

## History

**November 6, 2026: the book starts.** The Quarto book is set up with the Census Data and APIs
chapter, an introduction, the webR extension for in-browser R, and table IDs.

**November 7: publishing and sign-in.** The first plan, Netlify with a Netlify Identity login, was
tried and dropped the same day. Instead, the public copy is published to daveparr.com/geog215/ by a
GitHub Action, and webexercises self-check questions are added to the introduction. A Supabase
sign-in gate limited to approved emails is added, and geog215.org launches on Cloudflare (first with
`wrangler-action`, then with Cloudflare Workers Builds connected to the repo). Resend is set up to send
sign-in email from the geog215.org domain.

**November 8: access codes and the admin page.** Sign-in moves to instructor-issued access codes, and
the instructor admin page goes up at geog215.org/admin/. Students then sign in with their own email,
with a one-time setup code.

**November 12: analytics.** Google Analytics is added to geog215.org only.

**November 18: passwordless sign-in.** Passwords are replaced with emailed one-time codes and links.
The link opens a **Continue** button rather than signing in straight away, because UNC's email
scanner opens every link and would otherwise use it up.

**November 19: chapters and quizzes.** Two chapters are added: *R, RStudio, and R Markdown* and
*Introduction to Spatial Data Science*. Self-check answers and webR code runs are now recorded for
the admin page. Each chapter gets a Duolingo-style quiz page, with results on the admin page's new
**Chapter quizzes** tab. From here on, work goes through pull requests (#2 to #6).

**November 20: the quiz cartoon.** A cartoon of the instructor now cheers on right answers with a
speech bubble and appears on the end-of-quiz screen (#7). Wrong answers get a sad face and a kind
word (#8).
