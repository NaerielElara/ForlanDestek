import os
import re
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from enum import Enum
from pathlib import Path
from typing import Annotated

import jwt
import psycopg
from argon2 import PasswordHasher
from argon2.exceptions import VerificationError
from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.staticfiles import StaticFiles
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field, field_validator
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool
from . import management


DATABASE_URL = os.environ.get("DATABASE_URL", "")
JWT_SECRET = os.environ.get("JWT_SECRET", "")
TOKEN_TTL_HOURS = int(os.environ.get("TOKEN_TTL_HOURS", "12"))
BOOTSTRAP_ADMIN_USERNAME = os.environ.get("BOOTSTRAP_ADMIN_USERNAME", "").strip()
BOOTSTRAP_ADMIN_PASSWORD = os.environ.get("BOOTSTRAP_ADMIN_PASSWORD", "")
PASSWORDS = PasswordHasher()
BEARER = HTTPBearer(auto_error=False)
POOL: ConnectionPool | None = None


class Role(str, Enum):
    admin = "admin"
    technician = "technician"
    customer = "customer"


class LoginInput(BaseModel):
    username: str = Field(min_length=1, max_length=128)
    password: str = Field(min_length=1, max_length=256)


class AccountInput(BaseModel):
    username: str = Field(min_length=3, max_length=128, pattern=r"^[A-Za-z0-9_.@+-]+$")
    display_name: str = Field(min_length=1, max_length=160)
    password: str = Field(min_length=12, max_length=256)
    role: Role

    @field_validator("display_name")
    @classmethod
    def display_name_not_blank(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("Display name cannot be blank")
        return value.strip()


class LicenseInput(BaseModel):
    account_id: int = Field(gt=0)
    expires_at: datetime | None = None


class TicketInput(BaseModel):
    category: str = Field(pattern=r"^(Yazılım|Sistem)$")
    title: str = Field(min_length=3, max_length=200)
    description: str = Field(min_length=1, max_length=10000)
    device_id: str | None = Field(default=None, max_length=32)

    @field_validator("device_id")
    @classmethod
    def ticket_device_id(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = re.sub(r"\s", "", value)
        if not re.fullmatch(r"[0-9]{3,12}", normalized):
            raise ValueError("Device ID must contain 3 to 12 digits")
        return normalized

    @field_validator("category", "title", "description")
    @classmethod
    def ticket_fields_not_blank(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("This field cannot be blank")
        return value.strip()


class MessageInput(BaseModel):
    message: str = Field(min_length=1, max_length=10000)

    @field_validator("message")
    @classmethod
    def message_not_blank(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("Message cannot be blank")
        return value.strip()


class StatusInput(BaseModel):
    status: str = Field(pattern=r"^(open|in_progress|waiting_customer|resolved|closed)$")
    note: str = Field(default='', max_length=10000)


class AccountStatusInput(BaseModel):
    disabled: bool


def database() -> ConnectionPool:
    if POOL is None:
        raise HTTPException(status_code=503, detail="Support service is not ready")
    return POOL


def bootstrap_admin(pool: ConnectionPool) -> None:
    if bool(BOOTSTRAP_ADMIN_USERNAME) != bool(BOOTSTRAP_ADMIN_PASSWORD):
        raise RuntimeError("Set both bootstrap admin environment variables or neither")
    if not BOOTSTRAP_ADMIN_USERNAME:
        return
    if len(BOOTSTRAP_ADMIN_PASSWORD) < 16:
        raise RuntimeError("Bootstrap admin password must be at least 16 characters")
    if len(BOOTSTRAP_ADMIN_USERNAME) < 3 or not re.fullmatch(
        r"[A-Za-z0-9_.@+-]+", BOOTSTRAP_ADMIN_USERNAME
    ):
        raise RuntimeError("Bootstrap admin username is not valid")
    with pool.connection() as conn:
        exists = conn.execute("SELECT 1 FROM accounts WHERE role = 'admin' LIMIT 1").fetchone()
        if exists:
            return
        conn.execute(
            "INSERT INTO accounts (username, display_name, password_hash, role) VALUES (%s, %s, %s, 'admin')",
            (BOOTSTRAP_ADMIN_USERNAME.lower(), "Forlan Yönetici", PASSWORDS.hash(BOOTSTRAP_ADMIN_PASSWORD)),
        )
        conn.commit()


def initialize_database(pool: ConnectionPool) -> None:
    with pool.connection() as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS accounts (
                id BIGSERIAL PRIMARY KEY,
                username TEXT NOT NULL UNIQUE,
                display_name TEXT NOT NULL,
                password_hash TEXT NOT NULL,
                role TEXT NOT NULL CHECK (role IN ('admin', 'technician', 'customer')),
                disabled BOOLEAN NOT NULL DEFAULT FALSE,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now()
            );
            CREATE TABLE IF NOT EXISTS licenses (
                id BIGSERIAL PRIMARY KEY,
                account_id BIGINT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                expires_at TIMESTAMPTZ,
                revoked BOOLEAN NOT NULL DEFAULT FALSE,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now()
            );
            CREATE INDEX IF NOT EXISTS licenses_account_idx ON licenses(account_id);
            CREATE TABLE IF NOT EXISTS tickets (
                id BIGSERIAL PRIMARY KEY,
                customer_id BIGINT NOT NULL REFERENCES accounts(id),
                category TEXT NOT NULL,
                title TEXT NOT NULL,
                description TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'in_progress', 'waiting_customer', 'resolved', 'closed')),
                assigned_to BIGINT REFERENCES accounts(id),
                created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
            );
            CREATE INDEX IF NOT EXISTS tickets_pool_idx ON tickets(status, updated_at DESC);
            CREATE INDEX IF NOT EXISTS tickets_customer_idx ON tickets(customer_id, updated_at DESC);
            ALTER TABLE tickets ADD COLUMN IF NOT EXISTS device_id TEXT;
            CREATE TABLE IF NOT EXISTS ticket_messages (
                id BIGSERIAL PRIMARY KEY,
                ticket_id BIGINT NOT NULL REFERENCES tickets(id) ON DELETE CASCADE,
                sender_id BIGINT NOT NULL REFERENCES accounts(id),
                message TEXT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now()
            );
            CREATE INDEX IF NOT EXISTS ticket_messages_ticket_idx ON ticket_messages(ticket_id, id);
            CREATE TABLE IF NOT EXISTS support_events (
                id BIGSERIAL PRIMARY KEY,
                ticket_id BIGINT NOT NULL REFERENCES tickets(id) ON DELETE CASCADE,
                customer_id BIGINT NOT NULL REFERENCES accounts(id),
                actor_id BIGINT NOT NULL REFERENCES accounts(id),
                kind TEXT NOT NULL CHECK (kind IN ('ticket_created', 'message', 'connection_request')),
                staff_visible BOOLEAN NOT NULL DEFAULT TRUE,
                message TEXT NOT NULL DEFAULT '',
                device_id TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now()
            );
            CREATE INDEX IF NOT EXISTS support_events_customer_idx ON support_events(customer_id, id);
            CREATE TABLE IF NOT EXISTS login_attempts (
                id BIGSERIAL PRIMARY KEY,
                username TEXT NOT NULL,
                source_ip TEXT NOT NULL DEFAULT 'unknown',
                attempted_at TIMESTAMPTZ NOT NULL DEFAULT now()
            );
            ALTER TABLE login_attempts ADD COLUMN IF NOT EXISTS source_ip TEXT NOT NULL DEFAULT 'unknown';
            CREATE INDEX IF NOT EXISTS login_attempts_recent_idx ON login_attempts(username, source_ip, attempted_at DESC);
            CREATE INDEX IF NOT EXISTS login_attempts_time_idx ON login_attempts(attempted_at);
            CREATE TABLE IF NOT EXISTS audit_log (
                id BIGSERIAL PRIMARY KEY,
                actor_id BIGINT REFERENCES accounts(id) ON DELETE SET NULL,
                action TEXT NOT NULL,
                object_type TEXT NOT NULL,
                object_id TEXT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now()
            );
        """)
        management.initialize(conn)
        conn.commit()


@asynccontextmanager
async def lifespan(_: FastAPI):
    global POOL
    if not DATABASE_URL or len(JWT_SECRET) < 32:
        raise RuntimeError("DATABASE_URL and a JWT_SECRET of at least 32 characters are required")
    POOL = ConnectionPool(DATABASE_URL, min_size=1, max_size=12, kwargs={"row_factory": dict_row}, open=True)
    POOL.wait()
    initialize_database(POOL)
    bootstrap_admin(POOL)
    yield
    POOL.close()


app = FastAPI(title="Forlan Destek Support API", version="0.1.0", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)


@app.middleware("http")
async def prevent_private_response_caching(request: Request, call_next):
    response = await call_next(request)
    response.headers["Cache-Control"] = "no-store"
    response.headers["Pragma"] = "no-cache"
    return response


def current_account(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(BEARER)],
    pool: Annotated[ConnectionPool, Depends(database)],
) -> dict:
    if credentials is None:
        raise HTTPException(status_code=401, detail="Sign in required")
    try:
        claims = jwt.decode(credentials.credentials, JWT_SECRET, algorithms=["HS256"], options={"require": ["sub", "exp", "iat"]})
        account_id = int(claims["sub"])
    except (jwt.InvalidTokenError, ValueError, KeyError):
        raise HTTPException(status_code=401, detail="Invalid or expired session")
    with pool.connection() as conn:
        account = conn.execute(
            "SELECT id, username, display_name, role, disabled, archived, session_version FROM accounts WHERE id = %s",
            (account_id,),
        ).fetchone()
        if account:
            management.validate_session(conn, claims, account)
    if not account or account["disabled"]:
        raise HTTPException(status_code=401, detail="Account is unavailable")
    return account


def require_staff(account: dict = Depends(current_account)) -> dict:
    if account["role"] not in (Role.admin.value, Role.technician.value):
        raise HTTPException(status_code=403, detail="Technician access required")
    return account


def require_admin(account: dict = Depends(current_account)) -> dict:
    if account["role"] != Role.admin.value:
        raise HTTPException(status_code=403, detail="Administrator access required")
    return account


def audit(conn: psycopg.Connection, actor_id: int, action: str, object_type: str, object_id: int | str) -> None:
    conn.execute(
        "INSERT INTO audit_log (actor_id,actor_name,action,object_type,object_id) VALUES (%s,COALESCE((SELECT display_name FROM accounts WHERE id=%s),''),%s,%s,%s)",
        (actor_id, actor_id, action, object_type, str(object_id)),
    )


def licensed_customer(conn: psycopg.Connection, account_id: int) -> bool:
    row = conn.execute(
        "SELECT 1 FROM licenses WHERE account_id = %s AND revoked = FALSE AND archived = FALSE AND (expires_at IS NULL OR expires_at > now()) LIMIT 1",
        (account_id,),
    ).fetchone()
    return row is not None


def add_support_event(
    conn: psycopg.Connection,
    ticket: dict,
    actor_id: int,
    kind: str,
    message: str = "",
    staff_visible: bool = True,
) -> int:
    # Serialize event inserts until commit so polling cannot skip an earlier uncommitted ID.
    conn.execute("SELECT pg_advisory_xact_lock(72639105)")
    event = conn.execute(
        "INSERT INTO support_events (ticket_id, customer_id, actor_id, kind, staff_visible, message, device_id) VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING id",
        (ticket["id"], ticket["customer_id"], actor_id, kind, staff_visible, message[:240], ticket.get("device_id")),
    ).fetchone()
    return event["id"]


@app.get("/api/events")
def list_events(
    after: Annotated[int | None, Query(ge=0)] = None,
    account: dict = Depends(current_account),
    pool: ConnectionPool = Depends(database),
) -> dict:
    with pool.connection() as conn:
        cursor = conn.execute("SELECT COALESCE(max(id), 0) AS cursor FROM support_events").fetchone()["cursor"]
        if after is None:
            return {"cursor": cursor, "events": []}
        is_staff = account["role"] in (Role.admin.value, Role.technician.value)
        events = conn.execute("""
            SELECT e.id, e.kind, e.ticket_id, e.created_at, e.message, e.device_id,
                   t.title AS ticket_title, e.actor_id AS sender_id,
                   COALESCE(a.display_name,e.sender_name,'Silinmiş kullanıcı') AS sender_name, COALESCE(a.role,e.sender_role,'technician') AS sender_role
            FROM support_events e JOIN tickets t ON t.id = e.ticket_id
            LEFT JOIN accounts a ON a.id = e.actor_id
            WHERE e.id > %s AND e.id <= %s AND e.actor_id IS DISTINCT FROM %s
              AND (e.customer_id = %s OR (e.staff_visible AND %s))
              AND (e.kind <> 'connection_request' OR EXISTS (
                  SELECT 1 FROM licenses l WHERE l.account_id = e.customer_id
                  AND l.revoked = FALSE AND l.archived=FALSE AND (l.expires_at IS NULL OR l.expires_at > now())
              ))
            ORDER BY e.id LIMIT 100
        """, (after, cursor, account["id"], account["id"], is_staff)).fetchall()
        return {"cursor": events[-1]["id"] if len(events) == 100 else cursor, "events": events}


@app.get("/healthz")
def health(pool: Annotated[ConnectionPool, Depends(database)]) -> dict:
    with pool.connection() as conn:
        conn.execute("SELECT 1")
    return {"status": "ok"}


@app.post("/api/auth/login")
def login(body: LoginInput, request: Request, pool: Annotated[ConnectionPool, Depends(database)]) -> dict:
    username = body.username.strip().lower()
    source_ip = request.headers.get("x-forwarded-for", "").split(",", maxsplit=1)[0].strip()
    if not source_ip and request.client:
        source_ip = request.client.host
    source_ip = source_ip[:64] or "unknown"
    with pool.connection() as conn:
        recent = conn.execute(
            "SELECT count(*) AS count FROM login_attempts WHERE username = %s AND source_ip = %s AND attempted_at > now() - interval '15 minutes'",
            (username, source_ip),
        ).fetchone()["count"]
        ip_recent = conn.execute(
            "SELECT count(*) AS count FROM login_attempts WHERE source_ip = %s AND attempted_at > now() - interval '15 minutes'",
            (source_ip,),
        ).fetchone()["count"]
        if recent >= 8 or ip_recent >= 40:
            raise HTTPException(status_code=429, detail="Too many login attempts. Try again later.")
        account = conn.execute("SELECT * FROM accounts WHERE username = %s", (username,)).fetchone()
        if not account or account["disabled"] or account['archived']:
            conn.execute("DELETE FROM login_attempts WHERE attempted_at < now() - interval '1 day'")
            conn.execute("INSERT INTO login_attempts (username, source_ip) VALUES (%s, %s)", (username, source_ip))
            conn.commit()
            raise HTTPException(status_code=401, detail="Invalid username or password")
        try:
            PASSWORDS.verify(account["password_hash"], body.password)
        except VerificationError:
            conn.execute("DELETE FROM login_attempts WHERE attempted_at < now() - interval '1 day'")
            conn.execute("INSERT INTO login_attempts (username, source_ip) VALUES (%s, %s)", (username, source_ip))
            conn.commit()
            raise HTTPException(status_code=401, detail="Invalid username or password")
        if account['role']=='customer':
            raise HTTPException(403,'Müşteri girişi için lisans kodunu kullanın.')
        conn.execute("DELETE FROM login_attempts WHERE username = %s", (username,))
        audit(conn, account["id"], "login", "account", account["id"])
        conn.commit()
        now = datetime.now(timezone.utc)
        token = jwt.encode({"sub": str(account["id"]), "ver":account['session_version'], "iat": now, "exp": now + timedelta(hours=TOKEN_TTL_HOURS)}, JWT_SECRET, algorithm="HS256")
        has_license = licensed_customer(conn, account["id"])
        return {
            "access_token": token,
            "token_type": "bearer",
            "expires_in": TOKEN_TTL_HOURS * 3600,
            "account": {"id": account["id"], "username": username, "display_name": account["display_name"], "role": account["role"], "licensed": has_license},
        }


@app.get("/api/me")
def me(account: dict = Depends(current_account), pool: ConnectionPool = Depends(database)) -> dict:
    with pool.connection() as conn:
        license = conn.execute('SELECT expires_at FROM licenses WHERE account_id=%s AND revoked=FALSE AND archived=FALSE AND (expires_at IS NULL OR expires_at>now()) ORDER BY expires_at DESC NULLS FIRST LIMIT 1',(account['id'],)).fetchone()
        return {**account, "licensed":license is not None, 'license_expires_at':license['expires_at'] if license else None}


@app.post("/api/admin/accounts", status_code=201)
def create_account(body: AccountInput, admin: dict = Depends(require_admin), pool: ConnectionPool = Depends(database)) -> dict:
    with pool.connection() as conn:
        try:
            row = conn.execute(
                "INSERT INTO accounts (username, display_name, password_hash, role) VALUES (%s, %s, %s, %s) RETURNING id, username, display_name, role, created_at",
                (body.username.lower(), body.display_name.strip(), PASSWORDS.hash(body.password), body.role.value),
            ).fetchone()
        except psycopg.errors.UniqueViolation:
            conn.rollback()
            raise HTTPException(status_code=409, detail="Username already exists")
        audit(conn, admin["id"], "account_created", "account", row["id"])
        conn.commit()
        return row


@app.get("/api/admin/accounts")
def list_accounts(_: dict = Depends(require_admin), pool: ConnectionPool = Depends(database)) -> list[dict]:
    with pool.connection() as conn:
        return conn.execute("SELECT a.id,a.username,a.display_name,a.role,a.disabled,a.archived,a.created_at,(SELECT count(*) FROM licenses l WHERE l.account_id=a.id) AS license_count,(SELECT count(*) FROM tickets t WHERE t.customer_id=a.id) AS ticket_count FROM accounts a ORDER BY a.created_at DESC").fetchall()


@app.patch("/api/admin/accounts/{account_id}/status")
def update_account_status(
    account_id: int,
    body: AccountStatusInput,
    admin: dict = Depends(require_admin),
    pool: ConnectionPool = Depends(database),
) -> dict:
    with pool.connection() as conn:
        if body.disabled:
            conn.execute("SELECT pg_advisory_xact_lock(72639104)")
        account = conn.execute(
            "SELECT id, role, disabled FROM accounts WHERE id = %s FOR UPDATE",
            (account_id,),
        ).fetchone()
        if not account:
            raise HTTPException(status_code=404, detail="Account not found")
        if body.disabled and account_id == admin["id"]:
            raise HTTPException(status_code=409, detail="You cannot disable your own account")
        if body.disabled and account["role"] == Role.admin.value:
            active_admins = conn.execute(
                "SELECT count(*) AS count FROM accounts WHERE role = 'admin' AND disabled = FALSE AND archived = FALSE"
            ).fetchone()["count"]
            if active_admins <= 1:
                raise HTTPException(status_code=409, detail="At least one active administrator is required")
        row = conn.execute(
            "UPDATE accounts SET disabled = %s WHERE id = %s RETURNING id, username, display_name, role, disabled",
            (body.disabled, account_id),
        ).fetchone()
        audit(conn, admin["id"], "account_disabled" if body.disabled else "account_enabled", "account", account_id)
        conn.commit()
        return row


@app.get("/api/admin/licenses")
def list_licenses(_: dict = Depends(require_admin), pool: ConnectionPool = Depends(database)) -> list[dict]:
    with pool.connection() as conn:
        return conn.execute("""
            SELECT l.id, l.account_id, a.username, a.display_name, l.expires_at,
                   l.revoked, l.created_at
            FROM licenses l JOIN accounts a ON a.id = l.account_id
            ORDER BY l.created_at DESC
        """).fetchall()


@app.post("/api/admin/licenses", status_code=201)
def create_license(body: LicenseInput, admin: dict = Depends(require_admin), pool: ConnectionPool = Depends(database)) -> dict:
    expires = body.expires_at
    if expires and expires.tzinfo is None:
        raise HTTPException(status_code=422, detail="expires_at must include a timezone")
    with pool.connection() as conn:
        account = conn.execute("SELECT id, role FROM accounts WHERE id = %s", (body.account_id,)).fetchone()
        if not account or account["role"] != Role.customer.value:
            raise HTTPException(status_code=404, detail="Customer account not found")
        row = conn.execute(
            "INSERT INTO licenses (account_id, expires_at) VALUES (%s, %s) RETURNING id, account_id, expires_at, created_at",
            (body.account_id, expires),
        ).fetchone()
        audit(conn, admin["id"], "license_created", "license", row["id"])
        conn.commit()
    return row


@app.post("/api/admin/licenses/{license_id}/revoke")
def revoke_license(license_id: int, admin: dict = Depends(require_admin), pool: ConnectionPool = Depends(database)) -> dict:
    with pool.connection() as conn:
        row = conn.execute("UPDATE licenses SET revoked = TRUE WHERE id = %s RETURNING id", (license_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="License not found")
        audit(conn, admin["id"], "license_revoked", "license", license_id)
        conn.commit()
    return {"revoked": True}


@app.post("/api/tickets", status_code=201)
def create_ticket(body: TicketInput, account: dict = Depends(current_account), pool: ConnectionPool = Depends(database)) -> dict:
    if account["role"] != Role.customer.value:
        raise HTTPException(status_code=403, detail="Customer account required")
    with pool.connection() as conn:
        if not licensed_customer(conn, account["id"]):
            raise HTTPException(status_code=403, detail="An active support license is required")
        row = conn.execute(
            "INSERT INTO tickets (customer_id, category, title, description, device_id) VALUES (%s, %s, %s, %s, %s) RETURNING *",
            (account["id"], body.category.strip(), body.title.strip(), body.description.strip(), body.device_id),
        ).fetchone()
        audit(conn, account["id"], "ticket_created", "ticket", row["id"])
        add_support_event(conn, row, account["id"], "ticket_created", row["description"])
        conn.commit()
        return row


@app.get("/api/tickets")
def list_tickets(account: dict = Depends(current_account), pool: ConnectionPool = Depends(database)) -> list[dict]:
    with pool.connection() as conn:
        return management.ticket_rows(conn,account)


def visible_ticket(conn: psycopg.Connection, ticket_id: int, account: dict) -> dict:
    ticket = conn.execute("SELECT * FROM tickets WHERE id = %s", (ticket_id,)).fetchone()
    if not ticket:
        raise HTTPException(status_code=404, detail="Ticket not found")
    if account["role"] not in (Role.admin.value, Role.technician.value) and ticket["customer_id"] != account["id"]:
        raise HTTPException(status_code=404, detail="Ticket not found")
    return ticket


@app.get("/api/tickets/{ticket_id}")
def get_ticket(ticket_id: int, account: dict = Depends(current_account), pool: ConnectionPool = Depends(database)) -> dict:
    with pool.connection() as conn:
        ticket = visible_ticket(conn, ticket_id, account)
        ticket["messages"] = conn.execute("""
            SELECT m.id, m.ticket_id, m.message, m.created_at, COALESCE(a.display_name,m.sender_name,'Silinmiş kullanıcı') AS sender_name, COALESCE(a.role,m.sender_role,'technician') AS sender_role
            FROM ticket_messages m LEFT JOIN accounts a ON a.id = m.sender_id
            WHERE m.ticket_id = %s ORDER BY m.id
        """, (ticket_id,)).fetchall()
        return ticket


@app.post("/api/tickets/{ticket_id}/messages", status_code=201)
def add_message(ticket_id: int, body: MessageInput, account: dict = Depends(current_account), pool: ConnectionPool = Depends(database)) -> dict:
    with pool.connection() as conn:
        ticket = management.locked_staff_ticket(conn,ticket_id,account) if account['role'] in ('admin','technician') else visible_ticket(conn, ticket_id, account)
        row = conn.execute(
            "INSERT INTO ticket_messages (ticket_id, sender_id, message) VALUES (%s, %s, %s) RETURNING id, ticket_id, message, created_at",
            (ticket_id, account["id"], body.message.strip()),
        ).fetchone()
        conn.execute("UPDATE tickets SET updated_at = now() WHERE id = %s", (ticket_id,))
        audit(conn, account["id"], "ticket_message_added", "ticket", ticket_id)
        add_support_event(conn, ticket, account["id"], "message", row["message"])
        conn.commit()
        return row


@app.post("/api/tickets/{ticket_id}/connection-request", status_code=201)
def request_ticket_connection(
    ticket_id: int,
    staff: dict = Depends(require_staff),
    pool: ConnectionPool = Depends(database),
) -> dict:
    with pool.connection() as conn:
        ticket = conn.execute("""
            SELECT t.* FROM tickets t JOIN accounts a ON a.id = t.customer_id
            WHERE t.id = %s AND a.disabled = FALSE AND a.archived=FALSE AND a.role = 'customer'
            FOR UPDATE OF t
        """, (ticket_id,)).fetchone()
        if not ticket:
            raise HTTPException(status_code=404, detail="Ticket not found")
        if ticket["status"] in ("resolved", "closed"):
            raise HTTPException(status_code=409, detail="This support ticket is closed")
        if not licensed_customer(conn, ticket["customer_id"]):
            raise HTTPException(status_code=403, detail="An active customer support license is required")
        if not ticket.get("device_id"):
            raise HTTPException(status_code=409, detail="The support ticket has no device ID")
        if ticket['assigned_to'] is not None and ticket['assigned_to'] != staff['id'] and staff['role'] != 'admin':
            raise HTTPException(409, 'Bu kayıt başka bir teknisyenin üzerinde.')
        conn.execute("UPDATE tickets SET assigned_to=%s,status='in_progress',updated_at=now() WHERE id=%s",(staff['id'],ticket_id))
        management.audit_detail(conn,staff,'ticket_claim','ticket',ticket_id,{'from':ticket['assigned_to'],'to':staff['id'],'reason':'connection'})
        event_id = add_support_event(conn, ticket, staff["id"], "connection_request", staff_visible=False)
        audit(conn, staff["id"], "ticket_connection_requested", "ticket", ticket_id)
        conn.commit()
        return {"ticket_id": ticket_id, "device_id": ticket["device_id"], "event_id": event_id}


@app.patch("/api/tickets/{ticket_id}/status")
def update_ticket_status(ticket_id: int, body: StatusInput, staff: dict = Depends(require_staff), pool: ConnectionPool = Depends(database)) -> dict:
    with pool.connection() as conn:
        management.locked_staff_ticket(conn, ticket_id, staff)
        if body.status=='closed' and not body.note.strip():
            raise HTTPException(422,'İptal açıklaması girin.')
        row = conn.execute(
            "UPDATE tickets SET status = %s, updated_at = now(), assigned_to = CASE WHEN assigned_to IS NULL THEN %s ELSE assigned_to END WHERE id = %s RETURNING id, status, assigned_to, updated_at",
            (body.status, staff["id"], ticket_id),
        ).fetchone()
        if body.note.strip():
            conn.execute('INSERT INTO ticket_messages(ticket_id,sender_id,message) VALUES (%s,%s,%s)',(ticket_id,staff['id'],body.note.strip()))
        management.audit_detail(conn,staff,'ticket_status_changed','ticket',ticket_id,{'status':body.status,'note':body.note.strip()})
        ticket=visible_ticket(conn,ticket_id,staff)
        add_support_event(conn,ticket,staff['id'],'message',f"Kayıt durumu: {body.status}. {body.note.strip()}")
        conn.commit()
        return row


import sys
management.register(app, sys.modules[__name__])
app.mount("/admin", StaticFiles(directory=Path(__file__).parent / "static", html=True), name="admin")
