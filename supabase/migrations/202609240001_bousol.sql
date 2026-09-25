-- Bousòl: schéma et règles d'accès. Les changements de rôle et d'opérations
-- sensibles sont faits par des fonctions contrôlées, jamais par le navigateur.
create type public.member_role as enum ('tresoriere', 'rh', 'direction', 'membre');
create type public.operation_type as enum ('cotisation', 'don', 'pret', 'remboursement', 'autre');
create type public.operation_status as enum ('en_attente', 'confirme', 'rejete');

create table public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null unique,
  full_name text not null,
  role public.member_role not null default 'membre',
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.organization_settings (
  id boolean primary key default true check (id),
  monthly_contribution_gdes integer not null default 500 check (monthly_contribution_gdes > 0),
  updated_at timestamptz not null default now()
);
insert into public.organization_settings(id, monthly_contribution_gdes) values (true, 500);

create table public.ledger (
  id bigint generated always as identity primary key,
  member_id uuid references public.profiles(user_id),
  member_name text not null,
  type public.operation_type not null,
  amount_gdes integer not null check (amount_gdes > 0),
  payment_method text not null check (payment_method in ('MonCash','NatCash','Virement BUH','Virement BNC','Virement Capital Bank','Virement Sogebank','Virement Unibank','Espèces')),
  note text not null default '' check (char_length(note) <= 500),
  status public.operation_status not null default 'en_attente',
  created_by uuid not null references public.profiles(user_id),
  created_at timestamptz not null default now(),
  reviewed_by uuid references public.profiles(user_id),
  reviewed_at timestamptz
);
create index ledger_created_at_idx on public.ledger(created_at desc);
create index ledger_member_idx on public.ledger(member_id, created_at desc);

create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles(user_id,email,full_name,role)
  values(new.id, lower(new.email), coalesce(nullif(trim(new.raw_user_meta_data->>'full_name'), ''), split_part(new.email,'@',1)), 'membre');
  return new;
end;
$$;
create trigger on_auth_user_created after insert on auth.users
for each row execute procedure public.handle_new_user();

create function public.current_role() returns public.member_role
language sql stable security definer set search_path = '' as $$
  select role from public.profiles where user_id = (select auth.uid()) and active;
$$;
create function public.is_finance_staff() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(public.current_role() in ('tresoriere','rh','direction'), false);
$$;
create function public.can_manage_funds() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(public.current_role() in ('tresoriere','direction'), false);
$$;
revoke all on function public.current_role() from public, anon;
revoke all on function public.is_finance_staff() from public, anon;
revoke all on function public.can_manage_funds() from public, anon;
grant execute on function public.current_role(), public.is_finance_staff(), public.can_manage_funds() to authenticated;

alter table public.profiles enable row level security;
alter table public.organization_settings enable row level security;
alter table public.ledger enable row level security;
revoke all on public.profiles, public.organization_settings, public.ledger from anon, authenticated;
grant select on public.profiles, public.organization_settings, public.ledger to authenticated;
grant usage, select on sequence public.ledger_id_seq to authenticated;

create policy "Profiles: self or authorized staff can read" on public.profiles
for select to authenticated using (user_id = (select auth.uid()) or (select public.is_finance_staff()));
create policy "Authenticated users can read contribution settings" on public.organization_settings
for select to authenticated using (true);
create policy "Staff can read the full ledger, members only their entries" on public.ledger
for select to authenticated using ((select public.is_finance_staff()) or member_id = (select auth.uid()) or created_by = (select auth.uid()));

create function public.submit_operation(
  p_type public.operation_type,
  p_amount_gdes integer,
  p_payment_method text,
  p_note text default '',
  p_member_id uuid default null,
  p_external_name text default null
) returns bigint
language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_role public.member_role; v_member public.profiles%rowtype; v_id bigint; v_status public.operation_status;
begin
  if v_user is null then raise exception 'Connexion requise.'; end if;
  select * into v_member from public.profiles where user_id = v_user and active;
  if not found then raise exception 'Compte inactif ou introuvable.'; end if;
  v_role := v_member.role;
  if p_amount_gdes is null or p_amount_gdes < 1 or p_amount_gdes > 100000000 then raise exception 'Montant invalide.'; end if;
  if p_payment_method not in ('MonCash','NatCash','Virement BUH','Virement BNC','Virement Capital Bank','Virement Sogebank','Virement Unibank','Espèces') then raise exception 'Moyen de paiement invalide.'; end if;
  if char_length(coalesce(p_note,'')) > 500 then raise exception 'Note trop longue.'; end if;
  if v_role = 'membre' and p_type not in ('cotisation','don','remboursement') then raise exception 'Type d’opération interdit.'; end if;
  if p_type = 'pret' and v_role not in ('tresoriere','direction') then raise exception 'Seule la trésorière ou la direction peut accorder un prêt.'; end if;
  if v_role = 'membre' and p_member_id is not null and p_member_id <> v_user then raise exception 'Vous ne pouvez utiliser que votre propre compte.'; end if;
  if p_type = 'pret' and p_member_id is null then raise exception 'Sélectionnez le membre emprunteur.'; end if;
  if p_member_id is not null then
    select * into v_member from public.profiles where user_id = p_member_id and active;
    if not found then raise exception 'Membre actif introuvable.'; end if;
    if v_role in ('membre','rh') and v_member.user_id <> v_user then raise exception 'Accès refusé.'; end if;
  end if;
  if v_role = 'membre' then p_member_id := v_user; end if;
  v_status := case when v_role in ('tresoriere','direction') then 'confirme'::public.operation_status else 'en_attente'::public.operation_status end;
  insert into public.ledger(member_id,member_name,type,amount_gdes,payment_method,note,status,created_by)
  values(p_member_id, case when p_member_id is not null then (select full_name from public.profiles where user_id=p_member_id) else coalesce(nullif(trim(p_external_name),''),v_member.full_name) end, p_type,p_amount_gdes,p_payment_method,coalesce(p_note,''),v_status,v_user)
  returning id into v_id;
  return v_id;
end;
$$;

create function public.review_operation(p_id bigint, p_status public.operation_status) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not (select public.can_manage_funds()) then raise exception 'Accès refusé.'; end if;
  if p_status not in ('confirme','rejete') then raise exception 'Décision invalide.'; end if;
  update public.ledger set status=p_status, reviewed_by=auth.uid(), reviewed_at=now()
  where id=p_id and status='en_attente';
  if not found then raise exception 'Opération en attente introuvable.'; end if;
end;
$$;
revoke all on function public.submit_operation(public.operation_type,integer,text,text,uuid,text) from public, anon;
revoke all on function public.review_operation(bigint,public.operation_status) from public, anon;
grant execute on function public.submit_operation(public.operation_type,integer,text,text,uuid,text), public.review_operation(bigint,public.operation_status) to authenticated;

create function public.dashboard_summary() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_role public.member_role; v jsonb;
begin
  select role into v_role from public.profiles where user_id=v_user and active;
  if v_role is null then raise exception 'Connexion requise.'; end if;
  select jsonb_build_object(
    'fund_available', coalesce(sum(case when l.type='pret' then -l.amount_gdes else l.amount_gdes end) filter (where l.status='confirme' and (v_role in ('tresoriere','rh','direction') or l.member_id=v_user)),0),
    'monthly_contributions', coalesce(sum(l.amount_gdes) filter (where l.status='confirme' and l.type='cotisation' and l.created_at >= date_trunc('month', now()) and (v_role in ('tresoriere','rh','direction') or l.member_id=v_user)),0),
    'loans_outstanding', greatest(coalesce(sum(case when l.type='pret' then l.amount_gdes when l.type='remboursement' then -l.amount_gdes else 0 end) filter (where l.status='confirme' and (v_role in ('tresoriere','rh','direction') or l.member_id=v_user)),0),0),
    'active_members', case when v_role in ('tresoriere','rh','direction') then (select count(*) from public.profiles where role='membre' and active) else 0 end,
    'pending_operations', (select count(*) from public.ledger where status='en_attente' and (v_role in ('tresoriere','direction') or created_by=v_user)),
    'my_balance', coalesce(sum(case when l.type='pret' then -l.amount_gdes else l.amount_gdes end) filter (where l.status='confirme' and l.member_id=v_user),0),
    'my_pending', (select count(*) from public.ledger where status='en_attente' and created_by=v_user)
  ) into v from public.ledger l;
  return v;
end;
$$;
create function public.organization_members() returns table(user_id uuid,email text,full_name text,role public.member_role,active boolean,created_at timestamptz,balance_gdes bigint)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not (select public.is_finance_staff()) then raise exception 'Accès refusé.'; end if;
  return query select p.user_id,p.email,p.full_name,p.role,p.active,p.created_at,
    coalesce(sum(case when l.type='pret' then -l.amount_gdes else l.amount_gdes end) filter (where l.status='confirme'),0)::bigint
    from public.profiles p left join public.ledger l on l.member_id=p.user_id
    group by p.user_id order by p.full_name;
end;
$$;
revoke all on function public.dashboard_summary(),public.organization_members() from public,anon;
grant execute on function public.dashboard_summary(),public.organization_members() to authenticated;

-- Aucun client ne peut modifier directement profils ou écritures. Le rôle
-- trésorière initial est attribué au compte créé par l'administrateur du projet.
comment on table public.ledger is 'Journal immuable des cotisations, dons, prêts et remboursements Bousòl';

