# Tessa

Issue cards for a small team's apps. Editors file cards against a project, a reviewer triages them, selected cards export as a markdown batch an AI agent can act on, and the agent's report comes back in to close the loop.

What's here:

- `index.html` — the whole app. Vanilla JS, no build step. With `CONFIG` empty it runs on local demo data; with a Supabase URL and anon key it is the real thing.
- `schema.sql` — tables, triggers, row-level security, the screenshots bucket. Paste into the Supabase SQL editor once.
- `vendor/` — supabase-js and JSZip, pinned and served from this repo rather than a CDN.

Not here on purpose: `seed.sql` (the team passphrase, reviewer list and project list) stays outside the repo.

## Setup

### 1. Supabase (10 minutes)

1. Sign up at supabase.com (GitHub login works). New project: name `tessa`, region West EU, any database password (you never type it again).
2. SQL Editor → New query → paste all of `schema.sql` → Run. Then a second query with `seed.sql`, after setting the passphrase, reviewer email and project list in it.
3. Authentication → Emails → **Magic Link** template: the body must contain `{{ .Token }}` so the email carries a 6-digit code. Example body: `Your Tessa code is {{ .Token }}`. (If you skip this the email carries a link instead; clicking it also signs you in, it's just less phone-friendly.)
4. Authentication → URL Configuration → Site URL: the GitHub Pages URL from step 2 once you have it (`https://<username>.github.io/tessa/`).
5. Project Settings → API: copy **Project URL** and the **anon public** key into `CONFIG` at the top of `index.html`.

Supabase free projects pause after about a week without traffic. Check whether that is still true on the project's dashboard; if it is, a daily ping from any always-on machine keeps it awake.

### 2. GitHub Pages (5 minutes)

1. Create an empty public repo named `tessa`.
2. Push `index.html`, `schema.sql`, `README.md` and `vendor/`. Never `seed.sql`.
3. Settings → Pages → Source: *Deploy from a branch*, branch `main`, folder `/ (root)`. The page is live at `https://<username>.github.io/tessa/` within a minute or two.

Updating the app afterwards is pushing a new `index.html`.

## How it works

**Filers** open the link, type the team passphrase once per device, then their name once, pick a project and add cards. No login. They can also reply when a card is *Needs info*, and confirm or send back a card that is *Implemented*. Those are the only changes a filer can make; a database trigger enforces it regardless of what the page sends.

**The reviewer** signs in with an emailed code (address must be in the `reviewers` table). They triage, edit, manage projects, export and paste reports.

**Export** takes *new* cards only. It creates a batch, writes one markdown file per project (routing block from the project record, then the cards), zips it with the screenshots, and sets the cards to *In progress* with the batch id stamped on them.

**Report-back**: the agent ends with one line per card — `PLZ-014 — done — what changed`. The reviewer opens the batch, pastes those lines, previews and applies. `done` → Implemented, `skipped`/`blocked` → Needs info, `rejected` → Rejected; the text becomes the reviewer note.

Statuses: new → needs info | rejected | in progress → implemented → verified.

## Card IDs

`PREFIX-NNN`, assigned by a database trigger that locks the project row, so two filers at once never collide. Moving a card to another project gives it a new id under that prefix and keeps the old one in `moved_from`. Prefixes are permanent once a project has cards.

## Data model

```
projects    id, name, prefix, repo, content_path, agent_notes, active, seq
cards       id, display_id, project_id, type, priority, status, title, "where",
            description, current_text, proposed_text, steps, expected, actual,
            filer_name, filer_reply, reviewer_note, batch_id,
            edited_by, edited_at, original (jsonb), moved_from, created_at, updated_at
screenshots id, card_id, storage_path, sort         (files live in the public `screenshots` bucket)
batches     id, no, project_id, card_ids[], exported_by, report, reported_at, created_at
reviewers   email
settings    key, value                              (the passphrase; no API access at all)
```

`where` is a reserved word in SQL — quote it in hand-written queries. Through supabase-js it is just a field.

## Security model

The anon key is public; the team passphrase is not. The page sends the passphrase as a request header and every everyday row-level-security policy requires it (`has_key()`), so without it the API returns nothing and accepts nothing. With it, visitors can read projects, cards and batches, insert cards and screenshots, and update cards — but the `cards_filer_guard` trigger limits a non-reviewer update to `filer_reply` and three status transitions (implemented → verified, implemented → new, needs info → new). Reviewers (signed in, email in `reviewers`) get everything. The service key never touches the browser. The page carries `noindex`, and the data is never in this repo.

Screenshots sit in a public bucket under unguessable paths; the bucket can't be listed (no select policy), and the only index of paths is the `screenshots` table, which needs the passphrase. Uploads can't be gated by the passphrase, so the bucket caps file size and type.
