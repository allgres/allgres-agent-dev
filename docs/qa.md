# QA

Three kinds of browser tests, from narrow to wide. All need a running dashboard
with the mock model on (`ALLGRES_ENABLE_MOCK=1`) and an administrator
`ui_admin` / `ui-admin-password`.

| Run | What it answers | Command |
| --- | --- | --- |
| Role navigation | Can each role reach and use each surface? | `npm run test:ui` |
| Feature effects | Does a feature *do* what its button says? (The result is read from the server, not the screen.) | `npm run test:ui` |
| Crawler | Does anything break when every button is pressed, in either language? | `npm run test:crawl` (`CRAWL_LANG=ko` for Korean) |

## The crawler

It opens every menu entry and tab (and the Canvas), presses each button once,
presses the buttons of any dialog that opens, and closes it unsaved. Buttons
that delete, sign out, reset or change a user are not pressed (`SKIP`, in
English and Korean). It reports:

- an uncaught error, a console error, a 5xx, a database error (`sqlstate` other than 22023, 42501 and P0001, which are refusals a form is allowed to give)
- an error notice that is a program error ("null is not an object")
- the page scrolling sideways; a title cut short
- text standing on end in a narrow column (the Korean one-letter-a-line fault)
- buttons in one row that are not the same height; a button beyond the window
- in Korean, a whole text left in English
- the notice `rate_limited`

`CRAWL_PAGES=Chat,Agents` limits it to some menu entries, `CRAWL_ONLY=canvas`
to the Canvas, `CRAWL_VERBOSE=1` prints each press. Run it against a fresh
database: it seeds an agent pair, a room, a project and a user of its own.

The crawler does not know what is *right*. A feature that only looks done
(a line on the Canvas that gives no permission) passes it; that is what the
feature-effect tests are for. When a bug is found by hand, add the check for it
to one of them.

In CI the crawler is the `browser-crawler` job (both languages); it may fail
without blocking until its findings have been read.
