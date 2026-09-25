-- Ajouter des rôles propres au vice-président et à la trésorière adjointe.
alter type public.member_role add value if not exists 'vice_president';
alter type public.member_role add value if not exists 'tresoriere_adjointe';
