-- wpp_bot schema
-- Usar com: psql -U wpp_admin -d wpp_bot -f schema.sql

CREATE TABLE IF NOT EXISTS wpp_messages (
  id SERIAL PRIMARY KEY,
  message_id TEXT UNIQUE,
  contact_number TEXT NOT NULL,
  direction TEXT NOT NULL CHECK (direction IN ('in', 'out_bot', 'out_human')),
  content TEXT,
  raw_payload JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_wpp_messages_contact 
  ON wpp_messages(contact_number, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_wpp_messages_direction 
  ON wpp_messages(direction, created_at DESC);

CREATE TABLE IF NOT EXISTS wpp_handoff_log (
  id SERIAL PRIMARY KEY,
  contact_number TEXT NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('pause', 'resume', 'expire')),
  triggered_by TEXT,
  ttl_seconds INTEGER,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_wpp_handoff_contact 
  ON wpp_handoff_log(contact_number, created_at DESC);
