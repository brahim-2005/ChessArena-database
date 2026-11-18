const fs = require('node:fs');
const path = require('node:path');
const { loadEnvConfig } = require('@next/env');
const { Client } = require('pg');

async function runMigrations() {
  loadEnvConfig(process.cwd());

  const connectionString = process.env.DATABASE_URL;
  if (!connectionString || !connectionString.startsWith('postgres')) {
    throw new Error(
      'Set DATABASE_URL to the Supabase Postgres connection string (Project Settings > Database > Connection string).'
    );
  }

  const schemaPaths = [
    path.join(__dirname, '../sql/schema.sql'),
    path.join(__dirname, '../sql/player_intelligence.sql'),
  ];
  const migrationSql = schemaPaths.map((schemaPath) => fs.readFileSync(schemaPath, 'utf8')).join('\n');
  const client = new Client({ connectionString });

  await client.connect();
  try {
    await client.query('BEGIN');
    await client.query(migrationSql);
    await client.query('COMMIT');
    console.log('ChessArena database schema applied successfully.');
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    await client.end();
  }
}

if (require.main === module) {
  runMigrations().catch(error => {
    console.error('Database migration failed:', error.message);
    process.exitCode = 1;
  });
}

module.exports = { runMigrations };
