# Bousòl — bourse de l’organisation

Version hébergée : pages publiques GitHub Pages; comptes, profils et registre dans Supabase Auth/Postgres. **Aucune donnée de transaction n’est incluse dans ce dépôt.** Les rôles et l’accès aux écritures sont contrôlés par PostgreSQL Row Level Security et des fonctions RPC. Ne mettez jamais une clé Supabase `secret` ou `service_role` dans `site/config.js`.

## Hébergement visé

- Site : `https://espoirpartage.github.io/bousol/` (le dépôt GitHub est public; l’application exige un compte connecté).
- Base et authentification : nouveau projet dans l’organisation Supabase `Espoirpartage`.
- Cotisation mensuelle : **500 GDES**.
- Moyens saisis au registre : MonCash, NatCash, BUH, BNC, Capital Bank, Sogebank, Unibank et espèces. Le site consigne les opérations; il ne transfère pas d’argent.

## Mise en service Supabase

1. Dans Supabase, créez un projet nommé `bousol` dans l’organisation `Espoirpartage`. Choisissez vous-même le mot de passe de base de données et gardez-le dans votre gestionnaire de mots de passe.
2. Dans les paramètres Auth, définissez l’URL du site et l’URL de redirection autorisée à `https://espoirpartage.github.io/bousol/`.
3. Créez le premier compte de la trésorière dans **Authentication → Users**. Après l’invitation et la première connexion, attribuez le rôle dans l’éditeur SQL en remplaçant le courriel :

   ```sql
   update public.profiles
   set role = 'tresoriere'
   where email = lower('courriel-de-la-tresoriere@exemple.com');
   ```

4. Dans les clés API du projet, copiez l’URL du projet et la clé **publishable** dans `site/config.js`. Cette clé est conçue pour le navigateur et sera publique; elle n’autorise que les opérations permises par les règles RLS.
5. La migration initiale est déjà appliquée au projet Supabase. Pour activer le déploiement automatique des mises à jour de la fonction d’invitation depuis GitHub, ajoutez `SUPABASE_ACCESS_TOKEN` et `SUPABASE_PROJECT_REF` dans `Settings → Secrets and variables → Actions`. La migration initiale a été exécutée directement dans SQL Editor; elle ne doit pas être rejouée par `db push`.
6. Dans les paramètres Auth de Supabase, désactivez l’inscription publique. Les nouveaux comptes doivent passer par le bouton **Inviter un membre**, qui envoie un lien par courriel.
7. Activez GitHub Pages avec la source **GitHub Actions**. Le workflow `pages.yml` publie automatiquement `site/` après un push sur `main`.

Le service de courriel Supabase de test est limité. Configurez un SMTP de l’organisation avant d’envoyer des invitations à plusieurs membres.

## GitHub Actions

Le workflow de pages publie seulement le contenu de `site/`. Le workflow GitHub déploie la fonction Edge `manage-members` lorsque les deux *Actions secrets* ci-dessous sont présents. Les migrations de base de données ne sont pas rejouées par ce workflow, car la migration initiale a été appliquée directement dans le projet existant.

- `SUPABASE_ACCESS_TOKEN` : jeton personnel Supabase;
- `SUPABASE_PROJECT_REF` : identifiant du projet, visible dans son URL (`qcrsuqtylhntdcrzbtbh`).

Ne publiez jamais le jeton personnel dans le dépôt, dans `config.js` ou dans une capture d’écran. La clé `sb_publishable_…` est la seule clé destinée au navigateur.

## Accès de l’application

- Trésorière et direction : inviter des comptes, saisir et confirmer les opérations, accorder des prêts, consulter les membres et télécharger le registre CSV.
- RH : consulter le registre et les profils; soumettre une opération pour validation.
- Membres : voir leur solde et leurs opérations; soumettre une cotisation, un don ou un remboursement. Les demandes attendent la validation de la trésorière ou de la direction.
- Prêts : diminuent le solde du membre; un solde négatif représente le montant à rembourser. Les écritures restent dans le registre même si un compte est désactivé.

La table de bord affiche les 500 opérations les plus récentes; les indicateurs et soldes sont calculés par la base sur le registre complet.

