-- ============================================================
-- Tessa v1 — Supabase schema
-- Paste the whole file into the Supabase SQL editor and run it once, then
-- run seed.sql (kept out of the repo: passphrase, reviewer list, projects).
-- Safe to re-run; not designed to migrate live data.
-- ============================================================

-- ---------- Tables ----------

create table if not exists public.projects (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  prefix        text not null unique check (prefix ~ '^[A-Z]{2,4}$'),
  repo          text not null default '',
  content_path  text not null default '',
  agent_notes   text not null default '',
  active        boolean not null default true,
  seq           integer not null default 0,
  created_at    timestamptz not null default now()
);

create table if not exists public.cards (
  id             uuid primary key default gen_random_uuid(),
  display_id     text not null unique,            -- set by trigger: PREFIX-NNN
  project_id     uuid not null references public.projects(id),
  type           text not null check (type in ('content','bug','feature','other')),
  priority       text not null check (priority in ('p1','p2','p3')),
  status         text not null default 'new'
                 check (status in ('new','needs_info','rejected','in_progress','implemented','verified')),
  title          text not null check (length(title) between 1 and 300),
  "where"        text not null default '',
  description    text not null default '',
  current_text   text not null default '',
  proposed_text  text not null default '',
  steps          text not null default '',
  expected       text not null default '',
  actual         text not null default '',
  filer_name     text not null check (length(filer_name) between 1 and 80),
  filer_reply    text not null default '',
  reviewer_note  text not null default '',
  batch_id       uuid,                              -- fk added after batches exists
  edited_by      text,
  edited_at      timestamptz,
  original       jsonb,
  moved_from     text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create table if not exists public.screenshots (
  id            uuid primary key default gen_random_uuid(),
  card_id       uuid not null references public.cards(id) on delete cascade,
  storage_path  text not null,
  sort          integer not null default 0,
  created_at    timestamptz not null default now()
);

create table if not exists public.batches (
  id           uuid primary key default gen_random_uuid(),
  no           integer generated always as identity unique,
  project_id   uuid references public.projects(id),
  card_ids     uuid[] not null default '{}',
  exported_by  text,
  report       text,
  reported_at  timestamptz,
  created_at   timestamptz not null default now()
);

alter table public.cards
  drop constraint if exists cards_batch_id_fkey,
  add constraint cards_batch_id_fkey foreign key (batch_id) references public.batches(id) on delete set null;

create table if not exists public.reviewers (
  email  text primary key check (email = lower(email))
);

-- Team passphrase lives here. No API policies at all: nothing reads it but has_key().
create table if not exists public.settings (
  key    text primary key,
  value  text not null
);

create index if not exists cards_project_idx on public.cards(project_id);
create index if not exists cards_status_idx  on public.cards(status);
create index if not exists screenshots_card_idx on public.screenshots(card_id);

-- ---------- Who is a reviewer ----------

create or replace function public.is_reviewer()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.reviewers where email = lower(coalesce(auth.jwt() ->> 'email', '')));
$$;

-- The team passphrase. The page sends it as the x-tessa-key header on every
-- request; PostgREST exposes request headers to SQL. Fails closed: no
-- passphrase row, or no header, means no access.
create or replace function public.has_key()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'x-tessa-key', '') <> ''
     and coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'x-tessa-key', '')
         = (select value from public.settings where key = 'passphrase');
$$;

-- Everyday access: the passphrase, or a signed-in reviewer.
create or replace function public.has_access()
returns boolean language sql stable security definer set search_path = public as $$
  select public.has_key() or public.is_reviewer();
$$;

-- Reviewer, or a trusted server-side role: the SQL editor (postgres) and the
-- service key (service_role, used by the Tessa MCP server). Runs as the caller
-- on purpose so current_user is the real role.
create or replace function public.is_privileged()
returns boolean language sql stable as $$
  select current_user in ('postgres', 'service_role', 'supabase_admin') or public.is_reviewer();
$$;

-- ---------- Triggers ----------

-- Human-readable IDs. Locks the project row so two filers at once can't collide.
create or replace function public.cards_assign_display_id()
returns trigger language plpgsql security definer set search_path = public as $$
declare p record;
begin
  if tg_op = 'UPDATE' and new.project_id = old.project_id then
    new.display_id := old.display_id;                      -- never editable directly
    return new;
  end if;
  select prefix, seq into p from public.projects where id = new.project_id for update;
  if not found then raise exception 'unknown project'; end if;
  update public.projects set seq = p.seq + 1 where id = new.project_id;
  new.display_id := p.prefix || '-' || lpad((p.seq + 1)::text, 3, '0');
  if tg_op = 'UPDATE' then
    new.moved_from := coalesce(old.moved_from, old.display_id);
  end if;
  return new;
end $$;

drop trigger if exists cards_display_id on public.cards;
create trigger cards_display_id
  before insert or update of project_id on public.cards
  for each row execute function public.cards_assign_display_id();

-- What a filer (anyone who isn't a signed-in reviewer) may do to a card:
--   insert: a plain new card, nothing pre-triaged
--   update: only filer_reply and status, and status only
--           implemented -> verified   ("yes, it's fixed")
--           implemented -> new        ("still not right", with a reply)
--           needs_info  -> new        (answered the reviewer's question)
create or replace function public.cards_filer_guard()
returns trigger language plpgsql set search_path = public as $$
begin
  if public.is_privileged() then return new; end if;
  if tg_op = 'INSERT' then
    if new.status <> 'new' or new.batch_id is not null or new.reviewer_note <> ''
       or new.edited_by is not null or new.original is not null or new.moved_from is not null
       or new.filer_reply <> '' then
      raise exception 'filers can only add new, untriaged cards';
    end if;
    return new;
  end if;
  -- UPDATE
  if new.project_id is distinct from old.project_id or new.type is distinct from old.type
     or new.priority is distinct from old.priority or new.title is distinct from old.title
     or new."where" is distinct from old."where" or new.description is distinct from old.description
     or new.current_text is distinct from old.current_text or new.proposed_text is distinct from old.proposed_text
     or new.steps is distinct from old.steps or new.expected is distinct from old.expected
     or new.actual is distinct from old.actual or new.filer_name is distinct from old.filer_name
     or new.reviewer_note is distinct from old.reviewer_note or new.batch_id is distinct from old.batch_id
     or new.edited_by is distinct from old.edited_by or new.edited_at is distinct from old.edited_at
     or new.original is distinct from old.original or new.moved_from is distinct from old.moved_from
     or new.created_at is distinct from old.created_at then
    raise exception 'only the reviewer can change that';
  end if;
  if new.status is distinct from old.status then
    if not ((old.status = 'implemented' and new.status in ('verified','new'))
         or (old.status = 'needs_info' and new.status = 'new')) then
      raise exception 'that status change is for the reviewer';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists cards_filer_guard on public.cards;
create trigger cards_filer_guard
  before insert or update on public.cards
  for each row execute function public.cards_filer_guard();

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

drop trigger if exists cards_touch on public.cards;
create trigger cards_touch before update on public.cards
  for each row execute function public.touch_updated_at();

-- ---------- Row-level security ----------
-- The page uses the public anon key. Everything everyday requires the team
-- passphrase header (has_access()); is_reviewer() unlocks the rest.

alter table public.projects    enable row level security;
alter table public.cards       enable row level security;
alter table public.screenshots enable row level security;
alter table public.batches     enable row level security;
alter table public.reviewers   enable row level security;
alter table public.settings    enable row level security;

-- projects: the team reads, reviewers write
drop policy if exists projects_read   on public.projects;
drop policy if exists projects_insert on public.projects;
drop policy if exists projects_update on public.projects;
drop policy if exists projects_delete on public.projects;
create policy projects_read   on public.projects for select to anon, authenticated using (public.has_access());
create policy projects_insert on public.projects for insert to authenticated with check (public.is_reviewer());
create policy projects_update on public.projects for update to authenticated using (public.is_reviewer()) with check (public.is_reviewer());
create policy projects_delete on public.projects for delete to authenticated using (public.is_reviewer());

-- cards: the team reads, inserts and updates (the filer guard trigger limits
-- what non-reviewers can change); reviewers delete
drop policy if exists cards_read   on public.cards;
drop policy if exists cards_insert on public.cards;
drop policy if exists cards_update on public.cards;
drop policy if exists cards_delete on public.cards;
create policy cards_read   on public.cards for select to anon, authenticated using (public.has_access());
create policy cards_insert on public.cards for insert to anon, authenticated with check (public.has_access());
create policy cards_update on public.cards for update to anon, authenticated using (public.has_access()) with check (public.has_access());
create policy cards_delete on public.cards for delete to authenticated using (public.is_reviewer());

-- screenshots table: the team reads and adds; reviewers delete
drop policy if exists shots_read   on public.screenshots;
drop policy if exists shots_insert on public.screenshots;
drop policy if exists shots_delete on public.screenshots;
create policy shots_read   on public.screenshots for select to anon, authenticated using (public.has_access());
create policy shots_insert on public.screenshots for insert to anon, authenticated with check (public.has_access());
create policy shots_delete on public.screenshots for delete to authenticated using (public.is_reviewer());

-- batches: the team reads (the card detail shows "Batch 3"); reviewers write
drop policy if exists batches_read   on public.batches;
drop policy if exists batches_insert on public.batches;
drop policy if exists batches_update on public.batches;
create policy batches_read   on public.batches for select to anon, authenticated using (public.has_access());
create policy batches_insert on public.batches for insert to authenticated with check (public.is_reviewer());
create policy batches_update on public.batches for update to authenticated using (public.is_reviewer()) with check (public.is_reviewer());

-- reviewers: a signed-in user can see only whether their own address is listed.
-- Nobody writes this table through the API — add reviewers in the SQL editor.
drop policy if exists reviewers_self on public.reviewers;
create policy reviewers_self on public.reviewers for select to authenticated
  using (email = lower(coalesce(auth.jwt() ->> 'email', '')));

-- ---------- Storage: the screenshots bucket ----------
-- Public bucket: an object is served by its URL, and the paths are unguessable
-- (card uuid + timestamp). There is deliberately no select policy, so nobody
-- can list the bucket; the only index of paths is the screenshots table, which
-- needs the passphrase. Uploads can't be gated by the passphrase (the storage
-- service doesn't pass headers through), so the bucket caps size and type.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('screenshots', 'screenshots', true, 20971520, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = true, file_size_limit = 20971520;

drop policy if exists "screenshots public read"   on storage.objects;
drop policy if exists "screenshots anyone uploads" on storage.objects;
drop policy if exists "screenshots reviewer deletes" on storage.objects;
create policy "screenshots anyone uploads"   on storage.objects for insert to anon, authenticated with check (bucket_id = 'screenshots');
create policy "screenshots reviewer deletes" on storage.objects for delete to authenticated using (bucket_id = 'screenshots' and public.is_reviewer());

-- ---------- Attachments: the files bucket ----------
-- Editors attach data files (CSV / XLSX / TXT / MD) that ride along in the export
-- bundle. Same shape as screenshots: public bucket, unguessable paths, no listing,
-- referenced only by the attachments table (which needs the passphrase). Uploads
-- can't be passphrase-gated (storage doesn't pass headers), so the bucket caps
-- size (10 MB) and type.

create table if not exists public.attachments (
  id            uuid primary key default gen_random_uuid(),
  card_id       uuid not null references public.cards(id) on delete cascade,
  storage_path  text not null,
  filename      text not null,
  mime          text not null default '',
  size          integer not null default 0,
  sort          integer not null default 0,
  created_at    timestamptz not null default now()
);
create index if not exists attachments_card_idx on public.attachments(card_id);

alter table public.attachments enable row level security;
drop policy if exists att_read   on public.attachments;
drop policy if exists att_insert on public.attachments;
drop policy if exists att_delete on public.attachments;
create policy att_read   on public.attachments for select to anon, authenticated using (public.has_access());
create policy att_insert on public.attachments for insert to anon, authenticated with check (public.has_access());
create policy att_delete on public.attachments for delete to authenticated using (public.is_reviewer());

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('attachments', 'attachments', true, 10485760, array['text/csv','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','text/plain','text/markdown'])
on conflict (id) do update set public = true, file_size_limit = 10485760, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "attachments anyone uploads"   on storage.objects;
drop policy if exists "attachments reviewer deletes" on storage.objects;
create policy "attachments anyone uploads"   on storage.objects for insert to anon, authenticated with check (bucket_id = 'attachments');
create policy "attachments reviewer deletes" on storage.objects for delete to authenticated using (bucket_id = 'attachments' and public.is_reviewer());

-- Now run seed.sql.
