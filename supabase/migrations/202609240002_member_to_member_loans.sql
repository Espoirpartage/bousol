-- Prêts directs entre membres : le prêteur et l'emprunteur sont liés à chaque écriture.
alter table public.ledger
  add column lender_member_id uuid references public.profiles(user_id),
  add column lender_name text not null default '';

create index ledger_lender_idx on public.ledger(lender_member_id, created_at desc);

drop policy "Staff can read the full ledger, members only their entries" on public.ledger;
create policy "Staff and operation parties can read ledger" on public.ledger
for select to authenticated using (
  (select public.is_finance_staff())
  or member_id = (select auth.uid())
  or lender_member_id = (select auth.uid())
  or created_by = (select auth.uid())
);

-- Invalider l'ancienne signature, qui permettait un prêt de la caisse.
revoke all on function public.submit_operation(public.operation_type,integer,text,text,uuid,text) from public, anon, authenticated;

create or replace function public.submit_operation(
  p_type public.operation_type,
  p_amount_gdes integer,
  p_payment_method text,
  p_note text default '',
  p_member_id uuid default null,
  p_external_name text default null,
  p_lender_id uuid default null
) returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_role public.member_role;
  v_actor public.profiles%rowtype;
  v_borrower public.profiles%rowtype;
  v_lender public.profiles%rowtype;
  v_id bigint;
  v_status public.operation_status;
  v_available bigint;
  v_owed bigint;
begin
  if v_user is null then raise exception 'Connexion requise.'; end if;
  select * into v_actor from public.profiles where user_id=v_user and active;
  if not found then raise exception 'Compte inactif ou introuvable.'; end if;
  v_role := v_actor.role;
  if p_amount_gdes is null or p_amount_gdes < 1 or p_amount_gdes > 100000000 then raise exception 'Montant invalide.'; end if;
  if p_payment_method not in ('MonCash','NatCash','Virement BUH','Virement BNC','Virement Capital Bank','Virement Sogebank','Virement Unibank','Espèces') then raise exception 'Moyen de paiement invalide.'; end if;
  if char_length(coalesce(p_note,'')) > 500 then raise exception 'Note trop longue.'; end if;

  if p_type='pret' then
    if p_member_id is null or p_lender_id is null then raise exception 'Sélectionnez le prêteur et l’emprunteur.'; end if;
    if p_member_id=p_lender_id then raise exception 'Le prêteur et l’emprunteur doivent être différents.'; end if;
    if v_role='membre' and p_lender_id<>v_user then raise exception 'Vous ne pouvez prêter que depuis votre propre solde.'; end if;
    select * into v_borrower from public.profiles where user_id=p_member_id and active for update;
    if not found then raise exception 'Emprunteur actif introuvable.'; end if;
    select * into v_lender from public.profiles where user_id=p_lender_id and active for update;
    if not found then raise exception 'Prêteur actif introuvable.'; end if;
    if v_borrower.role<>'membre' or v_lender.role<>'membre' then raise exception 'Les prêts sont réservés aux membres.'; end if;
    -- Les prêts débitent les deux parties; remboursements les recréditent.
    -- remboursements confirmés le rétablissent.
    select coalesce(sum(case
      when l.type in ('pret','remboursement') then
        case when l.type='pret' then -l.amount_gdes else l.amount_gdes end
      else l.amount_gdes
    end),0)::bigint into v_available
    from public.ledger l
    where l.status='confirme' and (
      (l.member_id=v_lender.user_id)
      or (l.lender_member_id=v_lender.user_id)
    );
    select v_available - coalesce(sum(l.amount_gdes),0)::bigint into v_available
    from public.ledger l
    where l.status='en_attente' and l.type='pret' and l.lender_member_id=v_lender.user_id;
    if v_available < p_amount_gdes then raise exception 'Solde disponible insuffisant pour ce prêt.'; end if;
    if v_role not in ('membre','tresoriere','direction') then raise exception 'Accès refusé pour accorder un prêt.'; end if;
    v_status := case when v_role in ('tresoriere','direction') then 'confirme'::public.operation_status else 'en_attente'::public.operation_status end;
    insert into public.ledger(member_id,member_name,lender_member_id,lender_name,type,amount_gdes,payment_method,note,status,created_by)
    values(v_borrower.user_id,v_borrower.full_name,v_lender.user_id,v_lender.full_name,'pret',p_amount_gdes,p_payment_method,coalesce(p_note,''),v_status,v_user)
    returning id into v_id;
    return v_id;
  end if;

  if p_type='remboursement' then
    if p_member_id is null then p_member_id:=v_user; end if;
    if v_role='membre' and p_member_id<>v_user then raise exception 'Vous ne pouvez rembourser que votre propre prêt.'; end if;
    if p_lender_id is null then raise exception 'Sélectionnez le membre qui vous a prêté.'; end if;
    select * into v_borrower from public.profiles where user_id=p_member_id and active for update;
    if not found then raise exception 'Emprunteur actif introuvable.'; end if;
    select * into v_lender from public.profiles where user_id=p_lender_id and active for update;
    if not found then raise exception 'Prêteur actif introuvable.'; end if;
    if v_borrower.role<>'membre' or v_lender.role<>'membre' then raise exception 'Les remboursements concernent les membres uniquement.'; end if;
    select coalesce(sum(case when type='pret' then amount_gdes else -amount_gdes end),0)::bigint into v_owed
    from public.ledger
    where status='confirme' and member_id=v_borrower.user_id and lender_member_id=v_lender.user_id
      and type in ('pret','remboursement');
    select v_owed - coalesce(sum(amount_gdes),0)::bigint into v_owed
    from public.ledger
    where status='en_attente' and type='remboursement'
      and member_id=v_borrower.user_id and lender_member_id=v_lender.user_id;
    if v_owed < p_amount_gdes then raise exception 'Le remboursement dépasse la dette restante envers ce prêteur.'; end if;
    v_status := case when v_role in ('tresoriere','direction') then 'confirme'::public.operation_status else 'en_attente'::public.operation_status end;
    insert into public.ledger(member_id,member_name,lender_member_id,lender_name,type,amount_gdes,payment_method,note,status,created_by)
    values(v_borrower.user_id,v_borrower.full_name,v_lender.user_id,v_lender.full_name,'remboursement',p_amount_gdes,p_payment_method,coalesce(p_note,''),v_status,v_user)
    returning id into v_id;
    return v_id;
  end if;

  if p_type not in ('cotisation','don','autre') then raise exception 'Type d’opération invalide.'; end if;
  if v_role='membre' and p_type not in ('cotisation','don') then raise exception 'Type d’opération interdit.'; end if;
  if p_lender_id is not null then raise exception 'Prêteur inattendu.'; end if;
  if v_role='membre' then p_member_id:=v_user; end if;
  if p_member_id is not null then
    select * into v_borrower from public.profiles where user_id=p_member_id and active;
    if not found then raise exception 'Membre actif introuvable.'; end if;
    if v_role in ('membre','rh') and v_borrower.user_id<>v_user then raise exception 'Accès refusé.'; end if;
  end if;
  v_status := case when v_role in ('tresoriere','direction') then 'confirme'::public.operation_status else 'en_attente'::public.operation_status end;
  insert into public.ledger(member_id,member_name,lender_member_id,lender_name,type,amount_gdes,payment_method,note,status,created_by)
  values(p_member_id,case when p_member_id is not null then v_borrower.full_name else coalesce(nullif(trim(p_external_name),''),v_actor.full_name) end,null,'',p_type,p_amount_gdes,p_payment_method,coalesce(p_note,''),v_status,v_user)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.review_operation(p_id bigint, p_status public.operation_status) returns void
language plpgsql security definer set search_path = '' as $$
declare v_row public.ledger%rowtype; v_available bigint; v_owed bigint;
begin
  if not (select public.can_manage_funds()) then raise exception 'Accès refusé.'; end if;
  if p_status not in ('confirme','rejete') then raise exception 'Décision invalide.'; end if;
  select * into v_row from public.ledger where id=p_id and status='en_attente' for update;
  if not found then raise exception 'Opération en attente introuvable.'; end if;
  if p_status='confirme' and v_row.type='pret' then
    perform 1 from public.profiles where user_id=v_row.lender_member_id for update;
    select coalesce(sum(case when type in ('pret','remboursement')
      then case when type='pret' then -amount_gdes else amount_gdes end
      else amount_gdes end),0)::bigint into v_available
    from public.ledger where status='confirme'
      and (member_id=v_row.lender_member_id or lender_member_id=v_row.lender_member_id);
    select v_available-coalesce(sum(amount_gdes),0)::bigint into v_available
    from public.ledger where status='en_attente' and type='pret' and lender_member_id=v_row.lender_member_id and id<>p_id;
    if v_available < v_row.amount_gdes then raise exception 'Solde disponible insuffisant pour confirmer ce prêt.'; end if;
  elsif p_status='confirme' and v_row.type='remboursement' then
    select coalesce(sum(case when type='pret' then amount_gdes else -amount_gdes end),0)::bigint into v_owed
    from public.ledger where status='confirme' and member_id=v_row.member_id and lender_member_id=v_row.lender_member_id
      and type in ('pret','remboursement');
    select v_owed-coalesce(sum(amount_gdes),0)::bigint into v_owed
    from public.ledger where status='en_attente' and type='remboursement'
      and member_id=v_row.member_id and lender_member_id=v_row.lender_member_id and id<>p_id;
    if v_owed < v_row.amount_gdes then raise exception 'Le remboursement dépasse la dette restante.'; end if;
  end if;
  update public.ledger set status=p_status,reviewed_by=auth.uid(),reviewed_at=now() where id=p_id;
end;
$$;

create or replace function public.dashboard_summary() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_user uuid:=auth.uid(); v_role public.member_role; v jsonb;
begin
  select role into v_role from public.profiles where user_id=v_user and active;
  if v_role is null then raise exception 'Connexion requise.'; end if;
  select jsonb_build_object(
    'fund_available',case when v_role in ('tresoriere','rh','direction') then coalesce((select sum(l.amount_gdes) from public.ledger l where l.status='confirme' and l.type in ('cotisation','don','autre')),0) else 0 end,
    'monthly_contributions',case when v_role in ('tresoriere','rh','direction') then coalesce((select sum(l.amount_gdes) from public.ledger l where l.status='confirme' and l.type='cotisation' and l.created_at>=date_trunc('month',now())),0) else 0 end,
    'loans_outstanding',case when v_role in ('tresoriere','rh','direction') then greatest(coalesce((select sum(case when x.type='pret' then x.amount_gdes else -x.amount_gdes end) from public.ledger x where x.status='confirme' and x.type in ('pret','remboursement')),0),0) else 0 end,
    'active_members',case when v_role in ('tresoriere','rh','direction') then (select count(*) from public.profiles where role='membre' and active) else 0 end,
    'pending_operations',(select count(*) from public.ledger where status='en_attente' and (v_role in ('tresoriere','direction') or created_by=v_user)),
    'my_balance',coalesce((select sum(case
      when l.type='pret' then -l.amount_gdes
      when l.type='remboursement' then l.amount_gdes
      else l.amount_gdes end)
      from public.ledger l where l.status='confirme' and
      (l.member_id=v_user or l.lender_member_id=v_user)),0),
    'my_pending',(select count(*) from public.ledger where status='en_attente' and created_by=v_user)
  ) into v;
  return coalesce(v,jsonb_build_object('fund_available',0,'monthly_contributions',0,'loans_outstanding',0,'active_members',0,'pending_operations',0,'my_balance',0,'my_pending',0));
end;
$$;

create or replace function public.organization_members() returns table(user_id uuid,email text,full_name text,role public.member_role,active boolean,created_at timestamptz,balance_gdes bigint)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not (select public.is_finance_staff()) then raise exception 'Accès refusé.'; end if;
  return query select p.user_id,p.email,p.full_name,p.role,p.active,p.created_at,
    coalesce(sum(case
      when l.type='pret' then -l.amount_gdes
      when l.type='remboursement' then l.amount_gdes
      else l.amount_gdes end) filter(where l.status='confirme'),0)::bigint
    from public.profiles p left join public.ledger l
      on (l.member_id=p.user_id or l.lender_member_id=p.user_id)
    group by p.user_id order by p.full_name;
end;
$$;

create or replace function public.loan_members() returns table(user_id uuid,full_name text)
language sql stable security definer set search_path = '' as $$
  select p.user_id,p.full_name from public.profiles p
  where (select public.current_role()) is not null and p.active and p.role='membre' and p.user_id<>(select auth.uid())
  order by p.full_name;
$$;

create or replace function public.my_lenders() returns table(user_id uuid,full_name text,remaining_gdes bigint)
language sql stable security definer set search_path = '' as $$
  select p.user_id,p.full_name,
    (select coalesce(sum(case when l.type='pret' then l.amount_gdes else -l.amount_gdes end),0)::bigint
     from public.ledger l where l.status='confirme' and l.member_id=(select auth.uid())
       and l.lender_member_id=p.user_id and l.type in ('pret','remboursement'))
  from public.profiles p
  where (select public.current_role()) is not null and exists(select 1 from public.ledger l where l.status='confirme' and l.member_id=(select auth.uid())
    and l.lender_member_id=p.user_id and l.type='pret')
  order by p.full_name;
$$;

revoke all on function public.submit_operation(public.operation_type,integer,text,text,uuid,text,uuid) from public,anon;
revoke all on function public.review_operation(bigint,public.operation_status) from public,anon;
revoke all on function public.dashboard_summary(),public.organization_members(),public.loan_members(),public.my_lenders() from public,anon;
grant execute on function public.submit_operation(public.operation_type,integer,text,text,uuid,text,uuid),public.review_operation(bigint,public.operation_status),public.dashboard_summary(),public.organization_members(),public.loan_members(),public.my_lenders() to authenticated;
