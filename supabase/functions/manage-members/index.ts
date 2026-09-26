import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const appOrigin = Deno.env.get('APP_ORIGIN') ?? 'https://espoirpartage.github.io';
const cors = {
  'Access-Control-Allow-Origin': appOrigin,
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return reply({ error: 'Méthode non autorisée.' }, 405);
  const url = Deno.env.get('SUPABASE_URL')!;
  const publishable = Deno.env.get('SUPABASE_PUBLISHABLE_KEY') ?? Deno.env.get('SUPABASE_ANON_KEY')!;
  const secret = Deno.env.get('SUPABASE_SECRET_KEY') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const authHeader = req.headers.get('Authorization') ?? '';
  const caller = createClient(url, publishable, { global: { headers: { Authorization: authHeader } } });
  const { data: { user }, error: authError } = await caller.auth.getUser();
  if (authError || !user) return reply({ error: 'Connexion requise.' }, 401);
  const admin = createClient(url, secret, { auth: { autoRefreshToken: false, persistSession: false } });
  const { data: profile } = await admin.from('profiles').select('role,active').eq('user_id', user.id).maybeSingle();
  if (!profile?.active || !['tresoriere', 'tresoriere_adjointe', 'rh', 'direction', 'vice_president'].includes(profile.role)) return reply({ error: 'Accès réservé à la trésorière et à la direction.' }, 403);
  try {
    const body = await req.json();
    if (body.action === 'invite') {
      const email = String(body.email ?? '').trim().toLowerCase();
      const fullName = String(body.fullName ?? '').trim();
      const role = String(body.role ?? 'membre');
      if (!/^\S+@\S+\.\S+$/.test(email) || !fullName || fullName.length > 120 || !['membre','rh','direction','vice_president','tresoriere','tresoriere_adjointe'].includes(role)) return reply({ error: 'Nom, courriel et rôle valides requis.' }, 400);
      const { data, error } = await admin.auth.admin.inviteUserByEmail(email, { data: { full_name: fullName }, redirectTo: body.redirectTo });
      if (error || !data.user) return reply({ error: error?.message ?? 'Invitation impossible.' }, 400);
      const { error: updateError } = await admin.from('profiles').update({ full_name: fullName, role, active: true, position_title: String(body.positionTitle ?? '').trim() || null }).eq('user_id', data.user.id);
      if (updateError) return reply({ error: updateError.message }, 500);
      return reply({ ok: true, userId: data.user.id }, 201);
    }
    if (body.action === 'disable' || body.action === 'set_role') {
      const userId = String(body.userId ?? '');
      if (!/^[0-9a-f-]{36}$/i.test(userId) || userId === user.id) return reply({ error: 'Compte cible invalide.' }, 400);
      const patch = body.action === 'disable' ? { active: false } : { role: body.role };
      if (body.action === 'set_role' && !['membre','rh','direction','vice_president','tresoriere','tresoriere_adjointe'].includes(body.role)) return reply({ error: 'Rôle invalide.' }, 400);
      const { error } = await admin.from('profiles').update(patch).eq('user_id', userId);
      if (error) return reply({ error: error.message }, 400);
      return reply({ ok: true });
    }
    return reply({ error: 'Action inconnue.' }, 400);
  } catch (error) {
    return reply({ error: error instanceof Error ? error.message : 'Erreur inattendue.' }, 400);
  }
});

