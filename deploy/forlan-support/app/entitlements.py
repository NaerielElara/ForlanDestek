from fastapi import HTTPException


def initialize(conn):
    conn.execute('''
        ALTER TABLE licenses ADD COLUMN IF NOT EXISTS support_enabled BOOLEAN NOT NULL DEFAULT TRUE;
        ALTER TABLE licenses ALTER COLUMN support_enabled SET DEFAULT FALSE;
        ALTER TABLE licenses ADD COLUMN IF NOT EXISTS license_kind TEXT NOT NULL DEFAULT 'standard' CHECK(license_kind IN ('standard','trial'));
        ALTER TABLE licenses ADD COLUMN IF NOT EXISTS device_limit INTEGER NOT NULL DEFAULT 0 CHECK(device_limit BETWEEN 0 AND 1000);
        ALTER TABLE licenses ALTER COLUMN device_limit SET DEFAULT 1;
        ALTER TABLE tickets ADD COLUMN IF NOT EXISTS license_id BIGINT REFERENCES licenses(id) ON DELETE SET NULL;
        CREATE TABLE IF NOT EXISTS license_devices (
            id BIGSERIAL PRIMARY KEY,
            license_id BIGINT NOT NULL REFERENCES licenses(id) ON DELETE CASCADE,
            device_id TEXT NOT NULL,
            device_name TEXT NOT NULL DEFAULT '',
            app_version TEXT NOT NULL DEFAULT '',
            first_seen TIMESTAMPTZ NOT NULL DEFAULT now(),
            last_seen TIMESTAMPTZ NOT NULL DEFAULT now(),
            session_version INTEGER NOT NULL DEFAULT 0,
            revoked_at TIMESTAMPTZ,
            UNIQUE(license_id,device_id)
        );
        CREATE TABLE IF NOT EXISTS connection_children (
            session_id UUID PRIMARY KEY,
            parent_session_id UUID NOT NULL REFERENCES connection_leases(session_id) ON DELETE CASCADE
        );
        ALTER TABLE connection_leases ADD COLUMN IF NOT EXISTS license_id BIGINT REFERENCES licenses(id) ON DELETE SET NULL;
        ALTER TABLE connection_leases ADD COLUMN IF NOT EXISTS license_device_id BIGINT REFERENCES license_devices(id) ON DELETE SET NULL;
        DO $$ BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='support_events_kind_check' AND pg_get_constraintdef(oid) LIKE '%ticket_status%') THEN
                ALTER TABLE support_events DROP CONSTRAINT IF EXISTS support_events_kind_check;
                ALTER TABLE support_events ADD CONSTRAINT support_events_kind_check CHECK(kind IN ('ticket_created','message','connection_request','technician_notification','ticket_status'));
            END IF;
        END $$;
    ''')


def activate_device(conn, license, device_id, device_name, app_version):
    if not device_id:
        raise HTTPException(422, 'Bu lisans için cihaz bilgisi gerekiyor. Forlan Destek uygulamasını güncelleyin.')
    conn.execute('SELECT id FROM licenses WHERE id=%s FOR UPDATE', (license['id'],))
    existing = conn.execute('SELECT * FROM license_devices WHERE license_id=%s AND device_id=%s',
                            (license['id'], device_id)).fetchone()
    if existing and existing['revoked_at']:
        raise HTTPException(403, 'Bu cihazın lisans erişimi yönetici tarafından kaldırılmış. Yöneticinizle iletişime geçin.')
    if not existing:
        active = conn.execute('SELECT count(*) AS n FROM license_devices WHERE license_id=%s AND revoked_at IS NULL',
                              (license['id'],)).fetchone()['n']
        if license['device_limit'] and active >= license['device_limit']:
            raise HTTPException(409, 'Bu lisansın cihaz sınırına ulaşıldı. Yönetici panelinden cihazları düzenleyin.')
    return conn.execute('''INSERT INTO license_devices(license_id,device_id,device_name,app_version)
        VALUES (%s,%s,%s,%s) ON CONFLICT(license_id,device_id) DO UPDATE
        SET device_name=EXCLUDED.device_name,app_version=EXCLUDED.app_version,last_seen=now()
        RETURNING *''', (license['id'],device_id,device_name.strip(),app_version.strip())).fetchone()


def bind_session(conn, claims, account, license):
    # Unlimited legacy licenses remain usable until their clients receive the new build.
    if claims.get('license_device_id') is None:
        if license['device_limit']:
            raise HTTPException(401, 'Bu lisans için cihaz doğrulaması gerekiyor. Forlan Destek uygulamasını güncelleyip yeniden giriş yapın.')
        account.update(license_fields(license,None))
        return
    device = conn.execute('SELECT * FROM license_devices WHERE id=%s AND license_id=%s AND revoked_at IS NULL',
                          (claims.get('license_device_id'),license['id'])).fetchone()
    if not device or claims.get('device_id') != device['device_id'] or claims.get('device_ver') != device['session_version']:
        raise HTTPException(401, 'Cihaz lisans oturumu sona erdi. Lütfen uygulamayı güncelleyip yeniden giriş yapın.')
    conn.execute("UPDATE license_devices SET last_seen=now() WHERE id=%s AND last_seen<now()-interval '1 minute'", (device['id'],))
    account.update(license_id=license['id'], license_device_id=device['id'], device_id=device['device_id'], licensed=True,
                   support_enabled=license['support_enabled'], license_kind=license['license_kind'],
                   device_limit=license['device_limit'], license_expires_at=license['expires_at'])


def require_support(conn, account):
    if account['role'] in ('admin','technician'):
        return
    if not account.get('license_id') or not account.get('support_enabled'):
        raise HTTPException(403, 'Bu lisansa Forlan destek hizmeti dahil değil.')


def ticket_has_support(conn, ticket):
    if ticket.get('license_id'):
        return conn.execute('''SELECT 1 FROM licenses WHERE id=%s AND account_id=%s AND support_enabled=TRUE
            AND revoked=FALSE AND archived=FALSE AND (expires_at IS NULL OR expires_at>now())''',
                            (ticket['license_id'],ticket['customer_id'])).fetchone() is not None
    return conn.execute('''SELECT 1 FROM licenses WHERE account_id=%s AND support_enabled=TRUE
        AND revoked=FALSE AND archived=FALSE AND (expires_at IS NULL OR expires_at>now()) LIMIT 1''',
                        (ticket['customer_id'],)).fetchone() is not None


def license_fields(license, device_id):
    return {'licensed':True, 'license_id':license['id'], 'support_enabled':license['support_enabled'],
            'license_kind':license['license_kind'], 'device_limit':license['device_limit'],
            'device_id':device_id, 'license_expires_at':license['expires_at']}


def validate_trial(kind, duration_days):
    if kind=='trial' and (duration_days is None or duration_days>90):
        raise HTTPException(422, 'Deneme lisansı için 1 ile 90 gün arasında süre seçin.')
