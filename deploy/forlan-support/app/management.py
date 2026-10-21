import base64
import hashlib
import hmac
import json
import secrets
from datetime import datetime, timedelta, timezone
from typing import Literal
from uuid import UUID

import jwt
from argon2.exceptions import VerificationError
from cryptography.fernet import Fernet
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from fastapi import Depends, HTTPException, Request
from pydantic import BaseModel, Field, field_validator
from psycopg.types.json import Jsonb
from . import entitlements


class LicenseCodeInput(BaseModel):
    license_code: str = Field(min_length=10, max_length=128)
    device_id: str | None = Field(default=None, pattern=r'^[0-9]{3,12}$')
    device_name: str = Field(default='', max_length=160)
    app_version: str = Field(default='', max_length=40)


class FirmLicenseInput(BaseModel):
    account_id: int | None = Field(default=None, gt=0)
    display_name: str = Field(default='', max_length=160)
    duration_days: int | None = Field(default=None, ge=1, le=36500)
    support_enabled: bool = False
    license_kind: Literal['standard','trial'] = 'standard'
    device_limit: int = Field(default=1, ge=0, le=1000)


class LicenseActionInput(BaseModel):
    action: str = Field(pattern=r'^(renew|rotate|revoke|archive|restore|delete|configure)$')
    duration_days: int | None = Field(default=None, ge=1, le=36500)
    confirmation: str = ''
    support_enabled: bool | None = None
    license_kind: Literal['standard','trial'] | None = None
    device_limit: int | None = Field(default=None, ge=0, le=1000)


class DeviceActionInput(BaseModel):
    action: Literal['revoke','restore']


class AccountActionInput(BaseModel):
    action: str = Field(pattern=r'^(archive|restore|delete)$')
    confirmation: str = ''


class AccountPasswordInput(BaseModel):
    new_password: str = Field(min_length=6, max_length=256)
    current_password: str | None = Field(default=None, max_length=256)


class AssignmentInput(BaseModel):
    action: str = Field(pattern=r'^(claim|release|transfer)$')
    technician_id: int | None = Field(default=None, gt=0)
    note: str = Field(default='', max_length=10000)


class LeaseInput(BaseModel):
    device_id: str = Field(pattern=r'^[0-9]{3,12}$')
    session_id: str = Field(pattern=r'^[a-fA-F0-9-]{36}$')
    peer_id: str = Field(min_length=1, max_length=160)
    parent_session_id: str | None = Field(default=None, pattern=r'^[a-fA-F0-9-]{36}$')

    @field_validator('session_id','parent_session_id')
    @classmethod
    def valid_session_id(cls,value):
        return str(UUID(value)) if value else None

    @field_validator('peer_id')
    @classmethod
    def peer_not_blank(cls,value):
        if not value.strip():
            raise ValueError('Peer ID cannot be blank')
        return value


def initialize(conn):
    conn.execute('''
        ALTER TABLE accounts ADD COLUMN IF NOT EXISTS archived BOOLEAN NOT NULL DEFAULT FALSE;
        ALTER TABLE accounts ADD COLUMN IF NOT EXISTS session_version INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE licenses ADD COLUMN IF NOT EXISTS archived BOOLEAN NOT NULL DEFAULT FALSE;
        ALTER TABLE licenses ADD COLUMN IF NOT EXISTS code_hash TEXT;
        ALTER TABLE licenses ADD COLUMN IF NOT EXISTS code_cipher TEXT;
        ALTER TABLE licenses ADD COLUMN IF NOT EXISTS code_version INTEGER NOT NULL DEFAULT 0;
        CREATE UNIQUE INDEX IF NOT EXISTS licenses_code_hash_idx ON licenses(code_hash) WHERE code_hash IS NOT NULL;
        ALTER TABLE audit_log ADD COLUMN IF NOT EXISTS details JSONB NOT NULL DEFAULT '{}'::jsonb;
        ALTER TABLE audit_log ADD COLUMN IF NOT EXISTS actor_name TEXT NOT NULL DEFAULT '';
        ALTER TABLE ticket_messages ADD COLUMN IF NOT EXISTS sender_name TEXT;
        ALTER TABLE ticket_messages ADD COLUMN IF NOT EXISTS sender_role TEXT;
        ALTER TABLE ticket_messages ALTER COLUMN sender_id DROP NOT NULL;
        ALTER TABLE support_events ADD COLUMN IF NOT EXISTS sender_name TEXT;
        ALTER TABLE support_events ADD COLUMN IF NOT EXISTS sender_role TEXT;
        ALTER TABLE support_events ADD COLUMN IF NOT EXISTS recipient_id BIGINT REFERENCES accounts(id) ON DELETE CASCADE;
        ALTER TABLE support_events ALTER COLUMN actor_id DROP NOT NULL;
        DO $$ BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='support_events_kind_check' AND pg_get_constraintdef(oid) LIKE '%technician_notification%') THEN
                ALTER TABLE support_events DROP CONSTRAINT IF EXISTS support_events_kind_check;
                ALTER TABLE support_events ADD CONSTRAINT support_events_kind_check CHECK(kind IN ('ticket_created','message','connection_request','technician_notification'));
            END IF;
            IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='support_events_recipient_check') THEN
                ALTER TABLE support_events ADD CONSTRAINT support_events_recipient_check CHECK((kind='technician_notification')=(recipient_id IS NOT NULL));
            END IF;
            IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname='ticket_messages_sender_id_fkey' AND confdeltype<>'n') THEN
                ALTER TABLE ticket_messages DROP CONSTRAINT ticket_messages_sender_id_fkey;
                ALTER TABLE ticket_messages ADD CONSTRAINT ticket_messages_sender_id_fkey FOREIGN KEY(sender_id) REFERENCES accounts(id) ON DELETE SET NULL;
            END IF;
            IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname='support_events_actor_id_fkey' AND confdeltype<>'n') THEN
                ALTER TABLE support_events DROP CONSTRAINT support_events_actor_id_fkey;
                ALTER TABLE support_events ADD CONSTRAINT support_events_actor_id_fkey FOREIGN KEY(actor_id) REFERENCES accounts(id) ON DELETE SET NULL;
            END IF;
        END $$;
        CREATE TABLE IF NOT EXISTS ticket_reads (
            account_id BIGINT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            ticket_id BIGINT NOT NULL REFERENCES tickets(id) ON DELETE CASCADE,
            last_event BIGINT NOT NULL DEFAULT 0,
            PRIMARY KEY(account_id, ticket_id)
        );
        CREATE TABLE IF NOT EXISTS connection_leases (
            session_id UUID PRIMARY KEY,
            device_id TEXT NOT NULL,
            account_id BIGINT REFERENCES accounts(id) ON DELETE SET NULL,
            peer_id TEXT NOT NULL,
            premium BOOLEAN NOT NULL,
            started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            expires_at TIMESTAMPTZ NOT NULL,
            cooldown_until TIMESTAMPTZ NOT NULL,
            ended_at TIMESTAMPTZ
        );
        CREATE INDEX IF NOT EXISTS connection_leases_device_idx ON connection_leases(device_id, cooldown_until);
    ''')
    entitlements.initialize(conn)


def normalize_code(value):
    return ''.join(c for c in value.upper() if c not in ' -\t\r\n')


def create_code():
    alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    return 'FLN-' + '-'.join(''.join(secrets.choice(alphabet) for _ in range(5)) for _ in range(5))


def code_hash(code):
    return hashlib.sha256(normalize_code(code).encode()).hexdigest()


def cipher(secret):
    key = hmac.digest(secret.encode(), b'Forlan/license-code/encryption/v1', 'sha256')
    return Fernet(base64.urlsafe_b64encode(key))


def signing_key(secret):
    return Ed25519PrivateKey.from_private_bytes(hmac.digest(secret.encode(), b'Forlan/connection-policy/signing/v1', 'sha256'))


def audit_detail(conn, actor, action, kind, object_id, details):
    conn.execute('INSERT INTO audit_log (actor_id,actor_name,action,object_type,object_id,details) VALUES (%s,%s,%s,%s,%s,%s)',
                 (actor['id'], actor['display_name'], action, kind, str(object_id), Jsonb(details)))


def validate_session(conn, claims, account):
    if account.get('archived') or claims.get('ver', 0) != account.get('session_version', 0):
        raise HTTPException(401, 'Oturum sona erdi. Lütfen yeniden giriş yapın.')
    if 'license_id' in claims:
        license = conn.execute('SELECT * FROM licenses WHERE id=%s AND account_id=%s AND revoked=FALSE AND archived=FALSE AND (expires_at IS NULL OR expires_at>now())',
                               (claims['license_id'], account['id'])).fetchone()
        if not license or claims.get('license_ver') != license['code_version']:
            raise HTTPException(401, 'Lisansınız yenilenmiş, iptal edilmiş veya süresi dolmuş.')
        entitlements.bind_session(conn, claims, account, license)
    elif account['role'] in ('admin','technician'):
        account['device_id']=claims.get('device_id')


def register(app, core):
    db = core.database
    admin_dep = core.require_admin
    staff_dep = core.require_staff
    account_dep = core.current_account

    @app.post('/api/auth/license')
    def license_login(body: LicenseCodeInput, request: Request, pool=Depends(db)):
        source = request.headers.get('x-forwarded-for', '').split(',')[0].strip() or (request.client.host if request.client else 'unknown')
        source = source[:64]
        digest = code_hash(body.license_code)
        with pool.connection() as conn:
            conn.execute('SELECT pg_advisory_xact_lock(hashtextextended(%s, 61))', (source,))
            attempts = conn.execute("SELECT count(*) AS n FROM login_attempts WHERE source_ip=%s AND attempted_at>now()-interval '15 minutes'", (source,)).fetchone()['n']
            if attempts >= 40:
                raise HTTPException(429, 'Çok fazla deneme yapıldı. Daha sonra tekrar deneyin.')
            license = conn.execute('''SELECT l.*,a.username,a.display_name,a.role,a.disabled,a.archived AS account_archived,a.session_version
                FROM licenses l JOIN accounts a ON a.id=l.account_id WHERE l.code_hash=%s FOR UPDATE OF l''', (digest,)).fetchone()
            now = datetime.now(timezone.utc)
            if not license or license['disabled'] or license['account_archived'] or license['revoked'] or license['archived'] or (license['expires_at'] and license['expires_at'] <= now):
                conn.execute("DELETE FROM login_attempts WHERE attempted_at<now()-interval '1 day'")
                conn.execute('INSERT INTO login_attempts(username,source_ip) VALUES (%s,%s)', ('license:'+digest, source))
                conn.commit()
                raise HTTPException(401, 'Lisans kodu geçersiz, iptal edilmiş veya süresi dolmuş.')
            conn.execute('DELETE FROM login_attempts WHERE username=%s AND source_ip=%s', ('license:'+digest, source))
            device = entitlements.activate_device(conn, license, body.device_id, body.device_name, body.app_version) if body.device_id or license['device_limit'] else None
            claims = {'sub':str(license['account_id']), 'ver':license['session_version'], 'license_id':license['id'], 'license_ver':license['code_version'], 'license_device_id':device['id'] if device else None, 'device_id':body.device_id, 'device_ver':device['session_version'] if device else None, 'iat':now, 'exp':now+timedelta(hours=core.TOKEN_TTL_HOURS)}
            core.audit(conn, license['account_id'], 'license_login', 'license', license['id'])
            conn.commit()
            token = jwt.encode(claims,core.JWT_SECRET,algorithm='HS256')
            return {'access_token':token, 'refresh_token':core.sessions.issue_refresh(token,core.JWT_SECRET), 'account':{'id':license['account_id'],'display_name':license['display_name'],'role':license['role'],**entitlements.license_fields(license,body.device_id)}}

    @app.post('/api/admin/firm-licenses', status_code=201)
    def firm_license(body: FirmLicenseInput, admin=Depends(admin_dep), pool=Depends(db)):
        entitlements.validate_trial(body.license_kind,body.duration_days)
        with pool.connection() as conn:
            if body.account_id:
                account = conn.execute("SELECT * FROM accounts WHERE id=%s AND role='customer' AND archived=FALSE AND disabled=FALSE", (body.account_id,)).fetchone()
                if not account:
                    raise HTTPException(404, 'Aktif firma bulunamadı.')
            else:
                name = body.display_name.strip()
                if not name:
                    raise HTTPException(422, 'Firma adı girin.')
                account = conn.execute("INSERT INTO accounts(username,display_name,password_hash,role) VALUES (%s,%s,%s,'customer') RETURNING *",
                                       ('firm_'+secrets.token_hex(12),name,core.PASSWORDS.hash(secrets.token_urlsafe(40)))).fetchone()
                audit_detail(conn,admin,'firm_created','account',account['id'],{'name':name})
            code = create_code()
            expires = datetime.now(timezone.utc)+timedelta(days=body.duration_days) if body.duration_days else None
            license = conn.execute('''INSERT INTO licenses(account_id,expires_at,code_hash,code_cipher,code_version,support_enabled,license_kind,device_limit)
                VALUES (%s,%s,%s,%s,1,%s,%s,%s) RETURNING id,account_id,expires_at,support_enabled,license_kind,device_limit''',
                                   (account['id'],expires,code_hash(code),cipher(core.JWT_SECRET).encrypt(code.encode()).decode(),body.support_enabled,body.license_kind,body.device_limit)).fetchone()
            audit_detail(conn,admin,'license_created','license',license['id'],{'firm':account['display_name'],'expires_at':str(expires),'support_enabled':body.support_enabled,'license_kind':body.license_kind,'device_limit':body.device_limit})
            conn.commit()
            return {**license,'display_name':account['display_name'],'code':code}

    @app.get('/api/admin/license-codes')
    def license_codes(admin=Depends(admin_dep), pool=Depends(db)):
        with pool.connection() as conn:
            rows = conn.execute('''SELECT l.*,a.display_name,a.archived AS firm_archived,
                (SELECT count(*) FROM license_devices d WHERE d.license_id=l.id AND d.revoked_at IS NULL) AS active_devices
                FROM licenses l JOIN accounts a ON a.id=l.account_id ORDER BY l.id DESC''').fetchall()
            for row in rows:
                row['code'] = cipher(core.JWT_SECRET).decrypt(row.pop('code_cipher').encode()).decode() if row['code_cipher'] else None
                row.pop('code_hash',None)
            return rows

    @app.post('/api/admin/licenses/{license_id}/manage')
    def manage_license(license_id:int, body:LicenseActionInput, admin=Depends(admin_dep), pool=Depends(db)):
        with pool.connection() as conn:
            row = conn.execute('SELECT l.*,a.display_name FROM licenses l JOIN accounts a ON a.id=l.account_id WHERE l.id=%s FOR UPDATE OF l', (license_id,)).fetchone()
            if not row:
                raise HTTPException(404,'Lisans bulunamadı.')
            code = None
            if body.action=='delete':
                if body.confirmation != row['display_name']:
                    raise HTTPException(422,'Silmek için firma adını aynen yazın.')
                conn.execute('DELETE FROM licenses WHERE id=%s',(license_id,))
            elif body.action=='rotate':
                code = create_code()
                conn.execute('UPDATE licenses SET code_hash=%s,code_cipher=%s,code_version=code_version+1 WHERE id=%s',
                             (code_hash(code),cipher(core.JWT_SECRET).encrypt(code.encode()).decode(),license_id))
            elif body.action=='renew':
                entitlements.validate_trial(row['license_kind'],body.duration_days)
                expires = max(row['expires_at'] or datetime.now(timezone.utc),datetime.now(timezone.utc))+timedelta(days=body.duration_days) if body.duration_days else None
                conn.execute('UPDATE licenses SET expires_at=%s,revoked=FALSE,archived=FALSE WHERE id=%s',(expires,license_id))
            elif body.action=='revoke':
                conn.execute('UPDATE licenses SET revoked=TRUE,code_version=code_version+1 WHERE id=%s',(license_id,))
            elif body.action=='configure':
                kind=body.license_kind or row['license_kind']
                if kind=='trial' and (row['license_kind']!='trial' or body.duration_days is not None):
                    entitlements.validate_trial(kind,body.duration_days)
                active=conn.execute('SELECT count(*) AS n FROM license_devices WHERE license_id=%s AND revoked_at IS NULL',(license_id,)).fetchone()['n']
                if body.device_limit and active>body.device_limit:
                    raise HTTPException(409,'Önce aktif cihazları yeni sınırın altına indirin.')
                expires=datetime.now(timezone.utc)+timedelta(days=body.duration_days) if body.duration_days else row['expires_at']
                conn.execute('UPDATE licenses SET support_enabled=%s,license_kind=%s,device_limit=%s,expires_at=%s WHERE id=%s',
                             (row['support_enabled'] if body.support_enabled is None else body.support_enabled,kind,row['device_limit'] if body.device_limit is None else body.device_limit,expires,license_id))
            else:
                conn.execute('UPDATE licenses SET archived=%s,code_version=code_version+1 WHERE id=%s',(body.action=='archive',license_id))
            audit_detail(conn,admin,'license_'+body.action,'license',license_id,{'firm':row['display_name'],'duration_days':body.duration_days,'support_enabled':body.support_enabled,'license_kind':body.license_kind,'device_limit':body.device_limit})
            conn.commit()
            return {'success':True,'code':code}

    @app.get('/api/admin/licenses/{license_id}/devices')
    def license_devices(license_id:int, admin=Depends(admin_dep), pool=Depends(db)):
        with pool.connection() as conn:
            if not conn.execute('SELECT id FROM licenses WHERE id=%s',(license_id,)).fetchone():
                raise HTTPException(404,'Lisans bulunamadı.')
            return conn.execute('SELECT id,license_id,device_id,device_name,app_version,first_seen,last_seen,revoked_at FROM license_devices WHERE license_id=%s ORDER BY last_seen DESC',(license_id,)).fetchall()

    @app.post('/api/admin/licenses/{license_id}/devices/{device_id}/manage')
    def manage_device(license_id:int, device_id:str, body:DeviceActionInput, admin=Depends(admin_dep), pool=Depends(db)):
        with pool.connection() as conn:
            license=conn.execute('SELECT * FROM licenses WHERE id=%s FOR UPDATE',(license_id,)).fetchone()
            device=conn.execute('SELECT * FROM license_devices WHERE license_id=%s AND device_id=%s',(license_id,device_id)).fetchone()
            if not license or not device:
                raise HTTPException(404,'Lisans cihazı bulunamadı.')
            if body.action=='restore' and device['revoked_at'] and license['device_limit']:
                active=conn.execute('SELECT count(*) AS n FROM license_devices WHERE license_id=%s AND revoked_at IS NULL',(license_id,)).fetchone()['n']
                if active>=license['device_limit']:
                    raise HTTPException(409,'Lisansın cihaz sınırına ulaşıldı.')
            conn.execute('UPDATE license_devices SET revoked_at=CASE WHEN %s THEN now() ELSE NULL END,session_version=session_version+CASE WHEN %s THEN 1 ELSE 0 END WHERE id=%s',(body.action=='revoke',body.action=='revoke',device['id']))
            audit_detail(conn,admin,'license_device_'+body.action,'license',license_id,{'device_id':device_id,'device_name':device['device_name']})
            conn.commit()
            return {'success':True}

    @app.post('/api/admin/accounts/{account_id}/manage')
    def manage_account(account_id:int, body:AccountActionInput, admin=Depends(admin_dep), pool=Depends(db)):
        with pool.connection() as conn:
            conn.execute('SELECT pg_advisory_xact_lock(72639104)')
            row = conn.execute('SELECT * FROM accounts WHERE id=%s FOR UPDATE',(account_id,)).fetchone()
            if not row:
                raise HTTPException(404,'Hesap bulunamadı.')
            if body.action!='restore' and account_id==admin['id']:
                raise HTTPException(409,'Kendi yönetici hesabınızı kaldıramazsınız.')
            if body.action!='restore' and row['role']=='admin' and not row['archived'] and not row['disabled'] and conn.execute("SELECT count(*) AS n FROM accounts WHERE role='admin' AND archived=FALSE AND disabled=FALSE").fetchone()['n']<=1:
                raise HTTPException(409,'En az bir aktif yönetici kalmalı.')
            counts = conn.execute('SELECT count(*) AS n FROM tickets WHERE customer_id=%s',(account_id,)).fetchone()['n']
            audit_detail(conn,admin,'account_'+body.action,'account',account_id,{'name':row['display_name'],'role':row['role'],'deleted_customer_tickets':counts if body.action=='delete' else 0})
            if body.action=='delete':
                if body.confirmation!=row['display_name']:
                    raise HTTPException(422,'Silmek için firma/kullanıcı adını aynen yazın.')
                conn.execute('DELETE FROM tickets WHERE customer_id=%s',(account_id,))
                conn.execute('UPDATE tickets SET assigned_to=NULL WHERE assigned_to=%s',(account_id,))
                conn.execute('UPDATE ticket_messages SET sender_name=%s,sender_role=%s WHERE sender_id=%s',(row['display_name'],row['role'],account_id))
                conn.execute('UPDATE support_events SET sender_name=%s,sender_role=%s WHERE actor_id=%s',(row['display_name'],row['role'],account_id))
                conn.execute("UPDATE audit_log SET actor_name=%s WHERE actor_id=%s AND actor_name=''",(row['display_name'],account_id))
                conn.execute('DELETE FROM accounts WHERE id=%s',(account_id,))
            else:
                conn.execute('UPDATE accounts SET archived=%s,session_version=session_version+1 WHERE id=%s',(body.action=='archive',account_id))
            conn.commit()
            return {'success':True}

    @app.post('/api/admin/accounts/{account_id}/password')
    def update_account_password(account_id:int, body:AccountPasswordInput, admin=Depends(admin_dep), pool=Depends(db)):
        with pool.connection() as conn:
            row=conn.execute('SELECT id,display_name,role,password_hash FROM accounts WHERE id=%s FOR UPDATE',(account_id,)).fetchone()
            if not row:
                raise HTTPException(404,'Hesap bulunamadı.')
            if row['role'] not in ('admin','technician'):
                raise HTTPException(409,'Firma hesapları lisans koduyla giriş yapar; parola kullanmaz.')
            is_self=account_id==admin['id']
            if is_self:
                if not body.current_password:
                    raise HTTPException(422,'Kendi parolanızı değiştirmek için mevcut parolanızı girin.')
                try:
                    core.PASSWORDS.verify(row['password_hash'],body.current_password)
                except VerificationError:
                    raise HTTPException(403,'Mevcut parola yanlış.')
            conn.execute('UPDATE accounts SET password_hash=%s,session_version=session_version+1 WHERE id=%s',
                         (core.PASSWORDS.hash(body.new_password),account_id))
            audit_detail(conn,admin,'account_password_changed','account',account_id,{'name':row['display_name'],'role':row['role']})
            conn.commit()
            return {'success':True,'session_invalidated':is_self}

    @app.get('/api/admin/audit')
    def history(admin=Depends(admin_dep), pool=Depends(db)):
        with pool.connection() as conn:
            return conn.execute('''SELECT l.*,COALESCE(NULLIF(l.actor_name,''),a.display_name,'Silinmiş kullanıcı') AS actor_display_name
                FROM audit_log l LEFT JOIN accounts a ON a.id=l.actor_id ORDER BY l.id DESC LIMIT 500''').fetchall()

    @app.get('/api/technicians')
    def technicians(staff=Depends(staff_dep), pool=Depends(db)):
        with pool.connection() as conn:
            return conn.execute("SELECT id,display_name,role FROM accounts WHERE role IN ('admin','technician') AND disabled=FALSE AND archived=FALSE ORDER BY display_name").fetchall()

    @app.post('/api/tickets/{ticket_id}/assignment')
    def assignment(ticket_id:int, body:AssignmentInput, staff=Depends(staff_dep), pool=Depends(db)):
        with pool.connection() as conn:
            ticket=locked_staff_ticket(conn,ticket_id,staff)
            if ticket['status'] in ('resolved','closed'):
                raise HTTPException(409,'Sonuçlanan kayıt üstlenilemez.')
            target=staff['id'] if body.action=='claim' else None
            if body.action=='transfer':
                if not body.note.strip():
                    raise HTTPException(422,'Teknisyene iletilecek notu girin.')
                person=conn.execute("SELECT id FROM accounts WHERE id=%s AND role IN ('admin','technician') AND disabled=FALSE AND archived=FALSE",(body.technician_id,)).fetchone()
                if not person:
                    raise HTTPException(404,'Aktif teknisyen bulunamadı.')
                if person['id']==staff['id']:
                    raise HTTPException(422,'Bildirim gönderilecek başka bir teknisyen seçin.')
                conn.execute('SELECT pg_advisory_xact_lock(72639105)')
                event=conn.execute("INSERT INTO support_events(ticket_id,customer_id,actor_id,kind,recipient_id,message,device_id) VALUES (%s,%s,%s,'technician_notification',%s,%s,%s) RETURNING id",
                                   (ticket_id,ticket['customer_id'],staff['id'],person['id'],body.note.strip(),ticket.get('device_id'))).fetchone()
                audit_detail(conn,staff,'ticket_technician_notified','ticket',ticket_id,{'recipient_id':person['id'],'note':body.note.strip()})
                conn.commit()
                return {'assigned_to':ticket['assigned_to'],'notified_technician_id':person['id'],'event_id':event['id']}
            conn.execute('UPDATE tickets SET assigned_to=%s,status=%s,updated_at=now() WHERE id=%s',(target,'open' if target is None else 'in_progress',ticket_id))
            if body.note.strip():
                conn.execute('INSERT INTO ticket_messages(ticket_id,sender_id,message) VALUES (%s,%s,%s)',(ticket_id,staff['id'],body.note.strip()))
            audit_detail(conn,staff,'ticket_'+body.action,'ticket',ticket_id,{'from':ticket['assigned_to'],'to':target,'note':body.note.strip()})
            core.add_support_event(conn,ticket,staff['id'],'message',f"Kayıt {'üstlenildi' if target else 'havuza bırakıldı'}. {body.note.strip()}")
            conn.commit()
            return {'assigned_to':target}

    @app.post('/api/tickets/{ticket_id}/read')
    def read_ticket(ticket_id:int, account=Depends(account_dep), pool=Depends(db)):
        with pool.connection() as conn:
            core.visible_ticket(conn,ticket_id,account)
            cursor=conn.execute('SELECT COALESCE(max(id),0) AS n FROM support_events WHERE ticket_id=%s',(ticket_id,)).fetchone()['n']
            conn.execute('INSERT INTO ticket_reads(account_id,ticket_id,last_event) VALUES (%s,%s,%s) ON CONFLICT(account_id,ticket_id) DO UPDATE SET last_event=GREATEST(ticket_reads.last_event,EXCLUDED.last_event)',(account['id'],ticket_id,cursor))
            conn.commit()
            return {'read':True}

    @app.get('/api/tickets/{ticket_id}/history')
    def ticket_history(ticket_id:int, account=Depends(account_dep), pool=Depends(db)):
        with pool.connection() as conn:
            core.visible_ticket(conn,ticket_id,account)
            if account['role'] not in ('admin','technician'):
                return []
            return conn.execute("SELECT action,actor_name,details,created_at FROM audit_log WHERE object_type='ticket' AND object_id=%s ORDER BY id",(str(ticket_id),)).fetchall()

    @app.get('/api/policy/public-key')
    def policy_key():
        return {'public_key':base64.b64encode(signing_key(core.JWT_SECRET).public_key().public_bytes_raw()).decode()}

    @app.post('/api/connections/start')
    def start_connection(body:LeaseInput, request:Request, pool=Depends(db)):
        header=request.headers.get('authorization','')
        account=None
        if header:
            from fastapi.security import HTTPAuthorizationCredentials
            if not header.startswith('Bearer '):
                raise HTTPException(401,'Geçersiz oturum.')
            account=core.current_account(HTTPAuthorizationCredentials(scheme='Bearer',credentials=header[7:]),pool)
        with pool.connection() as conn:
            conn.execute('SELECT pg_advisory_xact_lock(hashtextextended(%s, 62))',(body.device_id,))
            if account and account.get('device_id') and account['device_id']!=body.device_id:
                raise HTTPException(403,'Bağlantı bu lisansın etkinleştirildiği cihazdan başlatılmalı.')
            premium=bool(account and (account['role'] in ('admin','technician') or account.get('licensed')))
            now=datetime.now(timezone.utc)
            alias=conn.execute('SELECT parent_session_id FROM connection_children WHERE session_id=%s',(body.session_id,)).fetchone()
            if alias and (not body.parent_session_id or str(alias['parent_session_id'])!=body.parent_session_id):
                raise HTTPException(409,'Dosya aktarım bağlantısı başka bir oturuma bağlı.')
            canonical=body.parent_session_id or body.session_id
            existing=conn.execute('SELECT * FROM connection_leases WHERE session_id=%s',(canonical,)).fetchone()
            if body.parent_session_id and (not existing or canonical==body.session_id or conn.execute('SELECT 1 FROM connection_leases WHERE session_id=%s',(body.session_id,)).fetchone()):
                raise HTTPException(409,'Dosya aktarımı için açık ana bağlantı bulunamadı.')
            if existing:
                legacy_unbound=bool(account and account.get('license_id') and account.get('device_limit')==0 and not account.get('license_device_id') and existing['license_id'] is None and existing['license_device_id'] is None)
                if existing['device_id']!=body.device_id or existing['peer_id']!=body.peer_id or existing['account_id']!=(account['id'] if account else None) or (not legacy_unbound and (existing['license_id']!=(account.get('license_id') if account else None) or existing['license_device_id']!=(account.get('license_device_id') if account else None))):
                    raise HTTPException(409,'Bağlantı kimliği zaten kullanılıyor veya farklı bir lisansa bağlı.')
                if existing['ended_at'] or existing['expires_at']<=now:
                    raise HTTPException(409,'Bu bağlantının süresi doldu.')
                if existing['premium'] and not premium:
                    raise HTTPException(403,'Bu bağlantının lisans yetkisi sona erdi.')
                expires=existing['expires_at']
                premium=existing['premium'] and premium
            else:
                if not premium:
                    previous=conn.execute('SELECT * FROM connection_leases WHERE device_id=%s AND premium=FALSE AND cooldown_until>now() AND (ended_at IS NULL OR expires_at<=now()) ORDER BY cooldown_until DESC LIMIT 1',(body.device_id,)).fetchone()
                    if previous:
                        wait=max(1,int((previous['cooldown_until']-now).total_seconds()))
                        raise HTTPException(429,{'message':'Lisanssız kullanımda tek bağlantı, 5 dakika sonrası 1 dakika ara ve 30 MB dosya gönderim sınırı uygulanır.','retry_after':wait})
                expires=now+timedelta(days=3650) if premium else now+timedelta(minutes=5)
                conn.execute('INSERT INTO connection_leases(session_id,device_id,account_id,peer_id,premium,expires_at,cooldown_until,license_id,license_device_id) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s)',
                             (body.session_id,body.device_id,account['id'] if account else None,body.peer_id,premium,expires,expires+timedelta(minutes=1),account.get('license_id') if account else None,account.get('license_device_id') if account else None))
            if body.parent_session_id:
                conn.execute('INSERT INTO connection_children(session_id,parent_session_id) VALUES (%s,%s) ON CONFLICT(session_id) DO NOTHING',(body.session_id,canonical))
            permit_exp=min(expires,now+timedelta(seconds=90))
            payload=json.dumps({'session_id':body.session_id,'policy_session_id':canonical,'device_id':body.device_id,'peer_id':body.peer_id,'premium':premium,'exp':int(permit_exp.timestamp()),'connection_expires':int(expires.timestamp())},separators=(',',':')).encode()
            signed=base64.b64encode(payload).decode()+'.'+base64.b64encode(signing_key(core.JWT_SECRET).sign(payload)).decode()
            conn.commit()
            return {'permit':signed,'premium':premium,'policy_session_id':canonical,'expires_at':expires,'refresh_after':30}

    @app.post('/api/connections/{session_id}/end')
    def end_connection(session_id:str, request:Request, pool=Depends(db)):
        try:
            session_id=str(UUID(session_id))
        except ValueError:
            raise HTTPException(422,'Geçersiz bağlantı kimliği.')
        # Ending a lease can never increase the allowance or erase the enforced cooldown.
        with pool.connection() as conn:
            child=conn.execute('DELETE FROM connection_children WHERE session_id=%s RETURNING session_id',(session_id,)).fetchone()
            if not child:
                conn.execute('UPDATE connection_leases SET ended_at=COALESCE(ended_at,now()) WHERE session_id=%s',(session_id,))
                conn.execute('DELETE FROM connection_children WHERE parent_session_id=%s',(session_id,))
            conn.commit()
            return {'ended':True}


def locked_staff_ticket(conn,ticket_id,staff):
    ticket=conn.execute('SELECT * FROM tickets WHERE id=%s FOR UPDATE',(ticket_id,)).fetchone()
    if not ticket:
        raise HTTPException(404,'Destek kaydı bulunamadı.')
    if ticket['assigned_to'] is not None and ticket['assigned_to']!=staff['id'] and staff['role']!='admin':
        raise HTTPException(409,'Bu kayıt başka bir teknisyenin üzerinde. İşlem için önce havuza bırakılmalı.')
    return ticket


def ticket_rows(conn,account):
    entitlements.require_support(conn,account)
    staff=account['role'] in ('admin','technician')
    return conn.execute('''SELECT t.*,a.display_name AS customer_name,a.archived AS customer_archived,s.display_name AS assigned_name,
        (SELECT count(*) FROM ticket_messages m WHERE m.ticket_id=t.id) AS message_count,
        (SELECT count(*) FROM support_events e WHERE e.ticket_id=t.id AND e.actor_id IS DISTINCT FROM %s
         AND (e.customer_id=%s OR (e.staff_visible AND %s))
         AND (e.recipient_id IS NULL OR (e.recipient_id=%s AND %s))
         AND e.id>COALESCE((SELECT last_event FROM ticket_reads r WHERE r.ticket_id=t.id AND r.account_id=%s),0)) AS unread_count
        FROM tickets t JOIN accounts a ON a.id=t.customer_id LEFT JOIN accounts s ON s.id=t.assigned_to
        WHERE (%s OR (t.customer_id=%s AND t.status NOT IN ('resolved','closed'))) ORDER BY t.updated_at DESC''',
        (account['id'],account['id'],staff,account['id'],staff,account['id'],staff,account['id'])).fetchall()
