-- Corrections suivies des cotisations, dons et autres écritures de fonds.
alter table public.ledger
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by uuid references public.profiles(user_id);

create table if not exists public.ledger_corrections (
  id bigint generated always as identity primary key,
  ledger_id bigint not null references public.ledger(id),
  action text not null check (action in ('correction','annulation')),
  before_row jsonb not null,
  actor_id uuid not null references public.profiles(user_id),
  created_at timestamptz not null default now()
);
alter table public.ledger_corrections enable row level security;
revoke all on public.ledger_corrections from public, anon, authenticated;

create or replace function public.correct_operation(
  p_id bigint,
  p_amount_gdes integer,
  p_payment_method text,
  p_note text,
  p_member_id uuid default null,
  p_external_name text default null
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_row public.ledger%rowtype;
  v_member public.profiles%rowtype;
  v_name text;
begin
  if not public.can_manage_funds() then raise exception 'Accès refusé.'; end if;
  if p_amount_gdes is null or p_amount_gdes < 1 or p_amount_gdes > 100000000 then raise exception 'Montant invalide.'; end if;
  if p_payment_method not in ('MonCash','NatCash','Virement BUH','Virement BNC','Virement Capital Bank','Virement Sogebank','Virement Unibank','Espèces') then raise exception 'Moyen de paiement invalide.'; end if;
  if char_length(coalesce(p_note,'')) > 500 then raise exception 'Note trop longue.'; end if;
  select * into v_row from public.ledger where id=p_id for update;
  if not found then raise exception 'Opération introuvable.'; end if;
  if v_row.cancelled_at is not null then raise exception 'Cette opération est déjà annulée.'; end if;
  if v_row.type in ('pret','remboursement') then raise exception 'Les prêts et remboursements ne peuvent pas être corrigés ici.'; end if;
  if p_member_id is not null then
    select * into v_member from public.profiles where user_id=p_member_id and active and role='membre';
    if not found then raise exception 'Membre actif introuvable.'; end if;
    v_name := v_member.full_name;
  else
    v_name := coalesce(nullif(trim(p_external_name),''),v_row.member_name);
  end if;
  insert into public.ledger_corrections(ledger_id,action,before_row,actor_id)
  values(v_row.id,'correction',to_jsonb(v_row),auth.uid());
  update public.ledger set amount_gdes=p_amount_gdes,payment_method=p_payment_method,note=coalesce(p_note,''),member_id=p_member_id,member_name=v_name
  where id=v_row.id;
end;
$$;

create or replace function public.cancel_operation(p_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare v_row public.ledger%rowtype;
begin
  if not public.can_manage_funds() then raise exception 'Accès refusé.'; end if;
  select * into v_row from public.ledger where id=p_id for update;
  if not found then raise exception 'Opération introuvable.'; end if;
  if v_row.cancelled_at is not null then raise exception 'Cette opération est déjà annulée.'; end if;
  if v_row.type in ('pret','remboursement') then raise exception 'Les prêts et remboursements doivent être réglés par une écriture de correction.'; end if;
  insert into public.ledger_corrections(ledger_id,action,before_row,actor_id)
  values(v_row.id,'annulation',to_jsonb(v_row),auth.uid());
  update public.ledger set status='rejete',cancelled_at=now(),cancelled_by=auth.uid(),reviewed_by=auth.uid(),reviewed_at=now()
  where id=v_row.id;
end;
$$;
revoke all on function public.correct_operation(bigint,integer,text,text,uuid,text),public.cancel_operation(bigint) from public,anon;
grant execute on function public.correct_operation(bigint,integer,text,text,uuid,text),public.cancel_operation(bigint) to authenticated;
