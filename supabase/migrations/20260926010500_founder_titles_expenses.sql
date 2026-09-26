-- Postes fondateurs privés, accès RH et dépenses de caisse.
-- Les noms sont ajoutés directement dans founder_roster sur le projet Supabase, jamais dans ce dépôt public.
alter table public.profiles add column if not exists position_title text;
create table if not exists public.founder_roster (
  id uuid primary key default gen_random_uuid(),
  full_name text,
  position_title text not null unique,
  profile_user_id uuid unique references public.profiles(user_id) on delete set null,
  display_order integer not null default 0,
  active boolean not null default true
);
alter table public.founder_roster enable row level security;
revoke all on public.founder_roster from anon, authenticated;
create or replace function public.can_manage_funds() returns boolean language sql stable security definer set search_path to '' as $f$
 select coalesce(public.current_role() in ('tresoriere','direction','vice_president','tresoriere_adjointe','rh'),false);
$f$;
create or replace function public.link_founder_profile() returns trigger language plpgsql security definer set search_path to '' as $f$
begin
 update public.founder_roster r set profile_user_id=new.user_id where r.profile_user_id is null and lower(trim(coalesce(r.full_name,'')))=lower(trim(coalesce(new.full_name,'')));
 update public.profiles p set position_title=r.position_title from public.founder_roster r where r.profile_user_id=new.user_id and p.user_id=new.user_id;
 return new;
end; $f$;
drop trigger if exists link_founder_profile_after_insert on public.profiles;
create trigger link_founder_profile_after_insert after insert on public.profiles for each row execute function public.link_founder_profile();
create or replace function public.organization_founders() returns table(id uuid,full_name text,position_title text,profile_user_id uuid,active boolean) language plpgsql stable security definer set search_path to '' as $f$
begin
 if not public.can_manage_funds() then raise exception 'Accès refusé.'; end if;
 return query select r.id,coalesce(r.full_name,'Nom à compléter'),r.position_title,r.profile_user_id,coalesce(p.active,false) from public.founder_roster r left join public.profiles p on p.user_id=r.profile_user_id where r.active order by r.display_order;
end; $f$;
revoke all on function public.organization_founders() from public,anon;
grant execute on function public.organization_founders() to authenticated;
do $body$ declare x record; d text; begin
 for x in select pg_get_functiondef(p.oid) def from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='submit_operation' loop
  d:=x.def;
  d:=replace(d,'''tresoriere'',''direction'',''vice_president'',''tresoriere_adjointe''','''tresoriere'',''direction'',''vice_president'',''tresoriere_adjointe'',''rh''');
  d:=replace(d,'''tresoriere'',''direction''','''tresoriere'',''direction'',''rh''');
  d:=replace(d,'''membre'',''tresoriere'',''direction'',''vice_president'',''tresoriere_adjointe''','''membre'',''tresoriere'',''direction'',''vice_president'',''tresoriere_adjointe'',''rh''');
  d:=replace(d,'''membre'',''rh''','''membre'''); execute d;
 end loop;
end $body$;
do $body$ declare d text; begin
 select pg_get_functiondef('public.dashboard_summary()'::regprocedure) into d;
 d:=replace(d,'sum(l.amount_gdes) from public.ledger l where l.status=''confirme'' and l.type in (''cotisation'',''don'',''autre'')','sum(case when l.type=''depense'' then -l.amount_gdes else l.amount_gdes end) from public.ledger l where l.status=''confirme'' and l.type in (''cotisation'',''don'',''autre'',''depense'')');
 d:=replace(d,'''tresoriere'',''direction'',''vice_president'',''tresoriere_adjointe'')','''tresoriere'',''direction'',''vice_president'',''tresoriere_adjointe'',''rh''); execute d;
end $body$;
create or replace function public.record_expense(p_amount_gdes integer,p_payment_method text,p_note text default '',p_responsible_name text default null) returns bigint language plpgsql security definer set search_path to '' as $f$
declare v_user uuid:=auth.uid(); v_name text; v_id bigint;
begin
 if v_user is null or not public.can_manage_funds() then raise exception 'Accès refusé.'; end if;
 if p_amount_gdes is null or p_amount_gdes<1 or p_amount_gdes>100000000 then raise exception 'Montant invalide.'; end if;
 if p_payment_method not in ('MonCash','NatCash','Virement BUH','Virement BNC','Virement Capital Bank','Virement Sogebank','Virement Unibank','Espèces') then raise exception 'Moyen de paiement invalide.'; end if;
 if char_length(coalesce(p_note,''))>500 then raise exception 'Note trop longue.'; end if;
 select full_name into v_name from public.profiles where user_id=v_user;
 insert into public.ledger(member_id,member_name,type,amount_gdes,payment_method,note,status,created_by) values(null,coalesce(nullif(trim(p_responsible_name),''),v_name),'depense',p_amount_gdes,p_payment_method,coalesce(p_note,''),'confirme',v_user) returning id into v_id;
 return v_id;
end; $f$;
revoke all on function public.record_expense(integer,text,text,text) from public,anon;
grant execute on function public.record_expense(integer,text,text,text) to authenticated;
-- Seed the founder roster privately in the Supabase SQL Editor after applying this migration.
