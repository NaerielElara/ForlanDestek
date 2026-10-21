import secrets
from datetime import datetime, timedelta, timezone

import jwt
from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials
from pydantic import BaseModel, Field


REFRESH_AUDIENCE = 'forlan-desktop-refresh'


class RestoreInput(BaseModel):
    refresh_token: str = Field(min_length=1, max_length=16384)
    device_id: str | None = Field(default=None, pattern=r'^[0-9]{3,12}$')


def issue_refresh(access_token, secret):
    claims = jwt.decode(access_token, secret, algorithms=['HS256'])
    now = datetime.now(timezone.utc)
    claims.update(token_use='refresh', aud=REFRESH_AUDIENCE, iat=now,
                  exp=now+timedelta(days=30), jti=secrets.token_urlsafe(24))
    return jwt.encode(claims, secret, algorithm='HS256')


def register(app, core):
    @app.post('/api/auth/restore')
    def restore(body: RestoreInput, pool=Depends(core.database)):
        try:
            claims = jwt.decode(body.refresh_token, core.JWT_SECRET, algorithms=['HS256'],
                                audience=REFRESH_AUDIENCE, options={'require':['sub','iat','exp','jti']})
            if claims.get('token_use') != 'refresh' or (claims.get('device_id') and claims['device_id'] != body.device_id):
                raise ValueError('Invalid saved session')
        except (jwt.InvalidTokenError, ValueError, KeyError):
            raise HTTPException(401, 'Kayıtlı oturum sona erdi. Lütfen yeniden giriş yapın.')
        for key in ('aud','token_use','jti'):
            claims.pop(key, None)
        now = datetime.now(timezone.utc)
        claims.update(iat=now, exp=now+timedelta(hours=core.TOKEN_TTL_HOURS))
        access = jwt.encode(claims, core.JWT_SECRET, algorithm='HS256')
        account = core.current_account(HTTPAuthorizationCredentials(scheme='Bearer', credentials=access), pool)
        return {'access_token':access, 'refresh_token':issue_refresh(access,core.JWT_SECRET),
                'expires_in':core.TOKEN_TTL_HOURS*3600, 'account':core.me(account,pool)}
