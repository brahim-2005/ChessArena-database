# ChessArena Database

This repository contains the Supabase/PostgreSQL schema, compatibility patches,
and migration runner.

## Files

- `sql/schema.sql` — canonical schema for a new or fully reviewed setup.
- `sql/fix_matchmaking_and_seed_puzzles.sql` — compatibility patch for existing
  projects, including game/profile fixes, clubs, messaging, and starter puzzles.
- `sql/game_invitations.sql` and `sql/fix_game_invitations.sql` — game invitation
  schema and compatibility migration.
- `scripts/migrate.js` — applies `sql/schema.sql` using a direct Postgres
  `DATABASE_URL` inside a transaction.

## Existing Supabase project

Review the SQL before applying it. For an existing installation, use the
appropriate compatibility SQL in the Supabase SQL Editor; do not blindly run
the complete schema over production data. Test changes in staging first.

## Migration runner

Requires Node.js 20.9 or newer.

```powershell
npm install
Copy-Item .env.example .env.local
```

Put the direct Postgres connection string in `.env.local`, replacing
`YOUR_DB_PASSWORD`. If the password contains reserved URL characters, URL-encode
them before using it. You can reset the database password from the Supabase
Dashboard if you no longer know it. Then run:

```powershell
npm run db:migrate
```

`DATABASE_URL` is a privileged secret. Never put it in frontend variables,
commit it, or share it in chat.
