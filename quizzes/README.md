# Chapter quiz question banks

Each chapter has a quiz page right after it (`chapters/<chapter>-quiz.qmd`), and each quiz page
draws its questions from a bank in this folder (`quizzes/<chapter>.json`). The quiz itself is
`assets/quiz/quiz.js` and `assets/quiz/quiz.css`.

A session asks `perSession` questions (default 10), chosen at random, with at least `minR` R
questions (default 3) if the bank has that many. Students answer one at a time. Any they miss come
back at the end, again and again, until every question is right. Each new quiz is a fresh random set.
On a right answer, a cartoon of the instructor pops up with a speech bubble ("Good job!", "Way to go!",
...), and again on the end-of-quiz screen with a message that depends on how it went. On a wrong
answer it frowns and says something kind ("Oops! So close."). The drawing (`coachSvg`, with the two
faces in `COACH_FACES`) and the phrases (`CHEERS`, `CONSOLES`, `FINISH_CHEERS`) are near the top of
`quiz.js`.

On geog215.org every answer is saved for the admin page's **Chapter quizzes** tab (see
`supabase/README.md`). On daveparr.com the quiz works the same way but nothing is saved.

## Adding a chapter quiz

1. Write `quizzes/<chapter>.json`. Copy an existing bank as a starting point.
2. Make `chapters/<chapter>-quiz.qmd` by copying another quiz page and changing the title, the link,
   and the `data-bank` path.
3. In `_quarto.yml`, list the quiz page right after its chapter.
4. In `admin/index.html`, add the bank's `id` to `BOOK_ORDER` so the admin page lists chapters in
   book order.

## Bank format

```json
{
  "id": "r-rstudio-rmarkdown",
  "title": "R, RStudio, and R Markdown",
  "perSession": 10,
  "minR": 4,
  "questions": [ ... ]
}
```

`id` is how results are stored, so **don't change a bank's `id` or a question's `id` once students
have used them**. Changing a question's wording is fine. Use 20–30 questions per bank.

Text in `prompt`, `choices` and `explain` can use `` `code` ``, `**bold**` and `*italic*`. Every
question should have an `explain`, which is shown after the student answers.

### Question types

**Multiple choice.** Choices are shuffled each time, so `answer` is the index (from 0) of the
right choice in the list as written. `code` is optional and is shown above the choices.

```json
{ "id": "max-temps", "type": "choice", "r": true,
  "prompt": "What does this code print?",
  "code": "temps <- c(71, 75, 68, 80, 77)\nmax(temps)",
  "choices": ["`[1] 80`", "`[1] 68`", "`[1] 74.2`", "`[1] 5`"],
  "answer": 0,
  "explain": "`max()` returns the largest value in the vector." }
```

**True or false.**

```json
{ "id": "knit-fresh", "type": "truefalse",
  "prompt": "A variable you created only in the Console will still exist when you knit.",
  "answer": false, "explain": "..." }
```

**Fill in the blank.** If `code` contains `___`, the answer box goes there; otherwise it goes
below the prompt. Spaces are ignored and `'` and `"` count as the same, so `c(1,2)` matches
`c(1, 2)`. Case matters unless you add `"ignoreCase": true`. For numbers, add `"numeric": true`
and optionally `"tolerance": 0.01`.

```json
{ "id": "fill-digits", "type": "fill",
  "prompt": "Complete the code so it rounds to 2 decimal places.",
  "code": "round(3.14159, ___ = 2)",
  "answers": ["digits"], "explain": "..." }
```

**Put the tiles in order.** The student taps tiles to build the answer. `extra` adds tiles that
don't belong. Tiles can repeat, as `|>` does here.

```json
{ "id": "order-pipe", "type": "order",
  "prompt": "Rewrite `round(sqrt(max(temps)), digits = 1)` with the pipe.",
  "answer": ["temps", "|>", "max()", "|>", "sqrt()", "|>", "round(digits = 1)"],
  "extra": ["mean()"], "explain": "..." }
```

**Write R code.** The student writes code in an editor and can run it. **Check** runs it with
webR (real R in the browser) in a fresh environment, then evaluates `check`, an R expression that
must be `TRUE` for the answer to count. `check` runs in the same environment, so it can look at
the student's variables. `.sds_code` holds their code as text, if you want to require something
like the pipe. If the student's code stops with an error, the answer is wrong. `solution` is shown
to students who get it wrong. Test every `check` against its `solution`.

```json
{ "id": "code-mean-temps", "type": "code",
  "prompt": "`temps` holds five daily highs. Store their average in a variable named `avg_temp`.",
  "starter": "temps <- c(71, 75, 68, 80, 77)\n",
  "check": "isTRUE(all.equal(avg_temp, 74.2))",
  "solution": "temps <- c(71, 75, 68, 80, 77)\navg_temp <- mean(temps)",
  "explain": "..." }
```

webR loads only when a session includes a code question, and it takes a few seconds the first
time. It can only use base R and packages that are installed in webR, and it has no internet
access, so code questions can't call tidycensus or other APIs. If R can't start in a student's
browser, they can skip the question, and it isn't counted.

### Which questions count as R questions

Fill-in, tile and code questions count toward `minR` unless they have `"r": false` (for example,
a tile question that orders the steps of a workflow). Multiple-choice and true/false questions
count only if they have `"r": true`.
