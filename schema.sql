-- IBBU Biotechnology Election Portal - Supabase database setup
-- Run the whole file in Supabase Dashboard > SQL Editor as project owner.
-- IMPORTANT: test in a test election first. Never expose the service_role key.
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.election_config (
  singleton boolean primary key default true check (singleton),
  id uuid not null default gen_random_uuid() unique,
  title text not null default 'IBBU Biotechnology Departmental Election',
  description text not null default 'Official departmental election for eligible Biotechnology students at IBBU Lapai.',
  status text not null default 'draft' check (status in ('draft','open','closed','results')),
  updated_at timestamptz not null default now()
);
insert into public.election_config(singleton) values(true) on conflict(singleton) do nothing;

create table if not exists public.election_positions (
  id text primary key,
  title text not null,
  description text not null default '',
  display_order integer not null default 0,
  active boolean not null default true
);
create table if not exists public.election_candidates (
  id uuid primary key default gen_random_uuid(),
  position_id text not null references public.election_positions(id),
  full_name text not null,
  level text not null default '',
  manifesto text not null default '',
  active boolean not null default true,
  created_at timestamptz not null default now()
);
-- Keep this table private: it contains identities and hashed voting access codes.
create table if not exists public.eligible_voters (
  id uuid primary key default gen_random_uuid(),
  matric_number text not null unique,
  access_code_hash text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint matric_format_allowed check (
    matric_number = upper(regexp_replace(trim(matric_number), '\s+', '', 'g')) and
    (matric_number ~ '^U2[2345]/FNS/BTG/.+$' or matric_number ~ '^U/FNS/BTG/(22|23|24|25)/.+$')
  )
);
-- This records that a voter has participated, but does not store their candidate choices.
create table if not exists public.voter_participation (
  id uuid primary key default gen_random_uuid(),
  election_id uuid not null,
  voter_id uuid not null references public.eligible_voters(id),
  submitted_at timestamptz not null default now(),
  unique(election_id, voter_id)
);
-- Ballots deliberately have no voter_id or matric_number column.
create table if not exists public.secret_ballots (
  id uuid primary key default gen_random_uuid(),
  election_id uuid not null,
  position_id text not null references public.election_positions(id),
  candidate_id uuid not null references public.election_candidates(id),
  submitted_at timestamptz not null default now()
);
create index if not exists secret_ballots_election_position_idx on public.secret_ballots(election_id, position_id);

-- No direct client access to underlying tables. All public actions go through carefully scoped RPCs.
alter table public.election_config enable row level security;
alter table public.election_positions enable row level security;
alter table public.election_candidates enable row level security;
alter table public.eligible_voters enable row level security;
alter table public.voter_participation enable row level security;
alter table public.secret_ballots enable row level security;
revoke all on public.election_config, public.election_positions, public.election_candidates, public.eligible_voters, public.voter_participation, public.secret_ballots from anon, authenticated;

create or replace function public.get_public_election()
returns jsonb language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare cfg public.election_config%rowtype; result_json jsonb := null;
begin
  select * into cfg from public.election_config where singleton = true;
  if cfg.status = 'results' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'position_title', p.title, 'candidate_name', c.full_name, 'votes', coalesce(v.cnt,0)
    ) order by p.display_order, coalesce(v.cnt,0) desc, c.full_name), '[]'::jsonb)
    into result_json
    from public.election_positions p
    join public.election_candidates c on c.position_id=p.id and c.active=true
    left join (select candidate_id, count(*)::integer cnt from public.secret_ballots where election_id=cfg.id group by candidate_id) v on v.candidate_id=c.id
    where p.active=true;
  end if;
  return jsonb_build_object(
    'election', jsonb_build_object('id',cfg.id,'title',cfg.title,'description',cfg.description,'status',cfg.status),
    'positions', coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'title',p.title,'description',p.description,'display_order',p.display_order) order by p.display_order) from public.election_positions p where p.active=true),'[]'::jsonb),
    'candidates', coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'position_id',c.position_id,'full_name',c.full_name,'level',c.level,'manifesto',c.manifesto) order by c.full_name) from public.election_candidates c join public.election_positions p on p.id=c.position_id where c.active=true and p.active=true),'[]'::jsonb),
    'results',result_json
  );
end; $$;

create or replace function public.verify_voter(p_matric text, p_access_code text)
returns jsonb language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare cfg public.election_config%rowtype; v public.eligible_voters%rowtype; m text;
begin
  select * into cfg from public.election_config where singleton=true;
  if cfg.status <> 'open' then return jsonb_build_object('ok',false,'message','Voting is not open.'); end if;
  m := upper(regexp_replace(trim(coalesce(p_matric,'')), '\s+', '', 'g'));
  if not (m ~ '^U2[2345]/FNS/BTG/.+$' or m ~ '^U/FNS/BTG/(22|23|24|25)/.+$') then
    return jsonb_build_object('ok',false,'message','This matriculation-number format is not eligible.');
  end if;
  select * into v from public.eligible_voters where matric_number=m and active=true and access_code_hash=encode(extensions.digest(upper(trim(coalesce(p_access_code,''))), 'sha256'),'hex');
  if not found then return jsonb_build_object('ok',false,'message','Matriculation number or access code is incorrect, or you are not on the approved voter register.'); end if;
  if exists(select 1 from public.voter_participation where election_id=cfg.id and voter_id=v.id) then
    return jsonb_build_object('ok',false,'message','A vote has already been submitted using this voter registration.');
  end if;
  return jsonb_build_object('ok',true,'message','Eligibility verified.');
end; $$;

create or replace function public.cast_ballot(p_matric text, p_access_code text, p_selections jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare cfg public.election_config%rowtype; v public.eligible_voters%rowtype; m text; s jsonb; pos_id text; cand_id uuid; expected_count integer; submitted_count integer; receipt text;
begin
  select * into cfg from public.election_config where singleton=true for update;
  if cfg.status <> 'open' then return jsonb_build_object('ok',false,'message','Voting is not open.'); end if;
  m := upper(regexp_replace(trim(coalesce(p_matric,'')), '\s+', '', 'g'));
  if not (m ~ '^U2[2345]/FNS/BTG/.+$' or m ~ '^U/FNS/BTG/(22|23|24|25)/.+$') then
    return jsonb_build_object('ok',false,'message','This matriculation-number format is not eligible.');
  end if;
  select * into v from public.eligible_voters where matric_number=m and active=true and access_code_hash=encode(extensions.digest(upper(trim(coalesce(p_access_code,''))), 'sha256'),'hex') for update;
  if not found then return jsonb_build_object('ok',false,'message','Matriculation number or access code is incorrect, or you are not on the approved voter register.'); end if;
  if exists(select 1 from public.voter_participation where election_id=cfg.id and voter_id=v.id) then
    return jsonb_build_object('ok',false,'message','A vote has already been submitted using this voter registration.');
  end if;
  if jsonb_typeof(p_selections) <> 'array' then return jsonb_build_object('ok',false,'message','Ballot format is invalid.'); end if;
  select count(*) into expected_count from public.election_positions where active=true;
  select count(*) into submitted_count from jsonb_array_elements(p_selections);
  if expected_count=0 or submitted_count<>expected_count then return jsonb_build_object('ok',false,'message','Please select exactly one candidate for every active position.'); end if;
  if (select count(distinct value->>'position_id') from jsonb_array_elements(p_selections)) <> expected_count then return jsonb_build_object('ok',false,'message','A position is missing or repeated on the ballot.'); end if;
  -- Validate all choices before recording participation.
  for s in select value from jsonb_array_elements(p_selections) loop
    pos_id := s->>'position_id';
    begin cand_id := (s->>'candidate_id')::uuid; exception when others then return jsonb_build_object('ok',false,'message','A selected candidate is invalid.'); end;
    if not exists(select 1 from public.election_positions p join public.election_candidates c on c.position_id=p.id where p.id=pos_id and p.active=true and c.id=cand_id and c.active=true) then
      return jsonb_build_object('ok',false,'message','One or more selections are invalid. Refresh the page and try again.');
    end if;
  end loop;
  insert into public.voter_participation(election_id,voter_id) values(cfg.id,v.id);
  for s in select value from jsonb_array_elements(p_selections) loop
    insert into public.secret_ballots(election_id,position_id,candidate_id) values(cfg.id,s->>'position_id',(s->>'candidate_id')::uuid);
  end loop;
  receipt := upper(substr(encode(extensions.digest(gen_random_uuid()::text,'sha256'),'hex'),1,12));
  return jsonb_build_object('ok',true,'message','Vote submitted successfully.','receipt_code',receipt);
exception when unique_violation then
  return jsonb_build_object('ok',false,'message','A vote has already been submitted using this voter registration.');
end; $$;

revoke all on function public.get_public_election() from public;
revoke all on function public.verify_voter(text,text) from public;
revoke all on function public.cast_ballot(text,text,jsonb) from public;
grant execute on function public.get_public_election() to anon, authenticated;
grant execute on function public.verify_voter(text,text) to anon, authenticated;
grant execute on function public.cast_ballot(text,text,jsonb) to anon, authenticated;

-- Example positions. Edit/add the department's officially approved positions before opening voting.
insert into public.election_positions(id,title,description,display_order) values
('president','President','Leads the departmental student association.',1),
('vice_president','Vice President','Supports the president and departmental activities.',2),
('general_secretary','General Secretary','Responsible for records and correspondence.',3),
('financial_secretary','Financial Secretary','Maintains financial records as authorised.',4),
('treasurer','Treasurer','Supports financial accountability.',5),
('pro','Public Relations Officer','Handles official communications.',6)
on conflict(id) do nothing;

-- Add eligible voters privately from the official register.
-- IMPORTANT: give each eligible student a unique random access code privately.
-- Example only: insert one voter and SHA-256 hash the access code. Replace the sample details.
-- INSERT INTO public.eligible_voters(matric_number, access_code_hash)
-- VALUES ('U22/FNS/BTG/0000', encode(extensions.digest('REPLACE-WITH-UNIQUE-PRIVATE-CODE', 'sha256'),'hex'));
-- Allowed formats: U22/FNS/BTG/..., U23/FNS/BTG/..., U24/FNS/BTG/..., U25/FNS/BTG/...
-- Also accepted: U/FNS/BTG/22/..., U/FNS/BTG/23/..., U/FNS/BTG/24/..., U/FNS/BTG/25/...
-- Do not insert real voter information into a public repository or website.

-- To open voting: UPDATE public.election_config SET status='open', updated_at=now() WHERE singleton=true;
-- To close voting: UPDATE public.election_config SET status='closed', updated_at=now() WHERE singleton=true;
-- To publish results after review: UPDATE public.election_config SET status='results', updated_at=now() WHERE singleton=true;
-- To reset for a new election, create a separate reviewed database/configuration; do not delete ballots casually.
