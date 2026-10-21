import base64
import json
import os
import unittest
from datetime import datetime, timedelta, timezone
from uuid import uuid4
from unittest.mock import patch

from fastapi import HTTPException
from fastapi.security import HTTPAuthorizationCredentials
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool
from starlette.requests import Request
from app import main as core, management as m
from app import sessions
import jwt


@unittest.skipUnless(os.environ.get('TEST_DATABASE_URL'), 'Requires isolated PostgreSQL test database')
class ManagementTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pool=ConnectionPool(os.environ['TEST_DATABASE_URL'],kwargs={'row_factory':dict_row})
        cls.pool.wait()
        core.initialize_database(cls.pool)
        core.initialize_database(cls.pool)

    @classmethod
    def tearDownClass(cls):
        cls.pool.close()

    def setUp(self):
        self.secret=patch.object(core,'JWT_SECRET','test-secret-not-for-production-'*3)
        self.secret.start()
        self.addCleanup(self.secret.stop)
        with self.pool.connection() as conn:
            conn.execute('TRUNCATE accounts,licenses,tickets,ticket_messages,support_events,ticket_reads,connection_leases,audit_log,login_attempts RESTART IDENTITY CASCADE')
            self.admin=conn.execute("INSERT INTO accounts(username,display_name,password_hash,role) VALUES ('admin','Yönetici','unused','admin') RETURNING *").fetchone()
            self.tech1=conn.execute("INSERT INTO accounts(username,display_name,password_hash,role) VALUES ('tech1','Birinci','unused','technician') RETURNING *").fetchone()
            self.tech2=conn.execute("INSERT INTO accounts(username,display_name,password_hash,role) VALUES ('tech2','İkinci','unused','technician') RETURNING *").fetchone()
            conn.commit()
        self.request=Request({'type':'http','headers':[],'client':('127.0.0.1',1234)})

    def call(self,path,**kwargs):
        route=next(r for r in core.app.routes if getattr(r,'path',None)==path)
        return route.endpoint(pool=self.pool,**kwargs)

    def license(self):
        row=self.call('/api/admin/firm-licenses',body=m.FirmLicenseInput(display_name='Hünkar',duration_days=30,support_enabled=True),admin=self.admin)
        result=self.call('/api/auth/license',body=m.LicenseCodeInput(license_code=row['code'],device_id='123456'),request=self.request)
        customer=core.current_account(HTTPAuthorizationCredentials(scheme='Bearer',credentials=result['access_token']),self.pool)
        return row,result,customer

    def test_license_code_remains_viewable_and_rotation_revokes_old_sessions(self):
        row,result,customer=self.license()
        codes=self.call('/api/admin/license-codes',admin=self.admin)
        self.assertEqual(codes[0]['code'],row['code'])
        self.assertEqual(result['account']['display_name'],'Hünkar')
        new=self.call('/api/admin/licenses/{license_id}/manage',license_id=row['id'],body=m.LicenseActionInput(action='rotate'),admin=self.admin)
        with self.assertRaises(HTTPException) as e:
            core.current_account(HTTPAuthorizationCredentials(scheme='Bearer',credentials=result['access_token']),self.pool)
        self.assertEqual(e.exception.status_code,401)
        with self.assertRaises(HTTPException):
            self.call('/api/auth/license',body=m.LicenseCodeInput(license_code=row['code'],device_id='123456'),request=self.request)
        fresh=self.call('/api/auth/license',body=m.LicenseCodeInput(license_code=new['code'],device_id='123456'),request=self.request)
        self.assertTrue(fresh['account']['licensed'])
        self.call('/api/admin/accounts/{account_id}/manage',account_id=customer['id'],body=m.AccountActionInput(action='archive'),admin=self.admin)
        with self.assertRaises(HTTPException):
            core.current_account(HTTPAuthorizationCredentials(scheme='Bearer',credentials=fresh['access_token']),self.pool)
        with self.assertRaises(HTTPException) as e:
            self.call('/api/admin/accounts/{account_id}/manage',account_id=self.admin['id'],body=m.AccountActionInput(action='delete',confirmation='Yönetici'),admin=self.admin)
        self.assertEqual(e.exception.status_code,409)

        with self.pool.connection() as conn:
            archived=conn.execute("INSERT INTO accounts(username,display_name,password_hash,role,archived) VALUES ('old-admin','Eski yönetici','unused','admin',TRUE) RETURNING id").fetchone()
            conn.commit()
        deleted=self.call('/api/admin/accounts/{account_id}/manage',account_id=archived['id'],body=m.AccountActionInput(action='delete',confirmation='Eski yönetici'),admin=self.admin)
        self.assertTrue(deleted['success'])

    def test_saved_session_restores_license_after_access_expires_but_checks_device_and_revocation(self):
        row,login,_=self.license()
        refresh=login['refresh_token']
        expired=jwt.decode(login['access_token'],core.JWT_SECRET,algorithms=['HS256'])
        expired['exp']=datetime.now(timezone.utc)-timedelta(seconds=1)
        with self.assertRaises(HTTPException):
            core.current_account(HTTPAuthorizationCredentials(scheme='Bearer',credentials=jwt.encode(expired,core.JWT_SECRET,algorithm='HS256')),self.pool)
        restored=self.call('/api/auth/restore',body=sessions.RestoreInput(refresh_token=refresh,device_id='123456'))
        self.assertTrue(restored['account']['licensed'])
        self.assertEqual(restored['account']['display_name'],'Hünkar')
        self.assertNotEqual(restored['refresh_token'],refresh)
        with self.assertRaises(HTTPException) as wrong_device:
            self.call('/api/auth/restore',body=sessions.RestoreInput(refresh_token=refresh,device_id='654321'))
        self.assertEqual(wrong_device.exception.status_code,401)
        with self.assertRaises(HTTPException) as refresh_as_access:
            core.current_account(HTTPAuthorizationCredentials(scheme='Bearer',credentials=refresh),self.pool)
        self.assertEqual(refresh_as_access.exception.status_code,401)
        self.call('/api/admin/licenses/{license_id}/manage',license_id=row['id'],body=m.LicenseActionInput(action='rotate'),admin=self.admin)
        with self.assertRaises(HTTPException) as revoked:
            self.call('/api/auth/restore',body=sessions.RestoreInput(refresh_token=restored['refresh_token'],device_id='123456'))
        self.assertEqual(revoked.exception.status_code,401)

    def test_saved_session_rejects_expired_refresh_and_archived_staff(self):
        now=datetime.now(timezone.utc)
        access=jwt.encode({'sub':str(self.tech1['id']),'ver':0,'device_id':'123456','iat':now,'exp':now+timedelta(hours=12)},core.JWT_SECRET,algorithm='HS256')
        refresh=sessions.issue_refresh(access,core.JWT_SECRET)
        restored=self.call('/api/auth/restore',body=sessions.RestoreInput(refresh_token=refresh,device_id='123456'))
        self.assertEqual(restored['account']['role'],'technician')
        expired=jwt.decode(refresh,core.JWT_SECRET,algorithms=['HS256'],audience=sessions.REFRESH_AUDIENCE)
        expired['exp']=now-timedelta(seconds=1)
        with self.assertRaises(HTTPException) as stale:
            self.call('/api/auth/restore',body=sessions.RestoreInput(refresh_token=jwt.encode(expired,core.JWT_SECRET,algorithm='HS256'),device_id='123456'))
        self.assertEqual(stale.exception.status_code,401)
        self.call('/api/admin/accounts/{account_id}/manage',account_id=self.tech1['id'],body=m.AccountActionInput(action='archive'),admin=self.admin)
        with self.assertRaises(HTTPException) as archived:
            self.call('/api/auth/restore',body=sessions.RestoreInput(refresh_token=refresh,device_id='123456'))
        self.assertEqual(archived.exception.status_code,401)

    def test_technician_notification_keeps_owner_and_targets_only_recipient(self):
        _,_,customer=self.license()
        ticket=core.create_ticket(core.TicketInput(category='Sistem',title='Destek isteği',description='Ayrıntı',device_id='123456'),customer,self.pool)
        core.request_ticket_connection(ticket['id'],self.tech1,self.pool)
        with self.assertRaises(HTTPException) as e:
            core.request_ticket_connection(ticket['id'],self.tech2,self.pool)
        self.assertEqual(e.exception.status_code,409)
        for reader in [self.tech1,self.tech2,self.admin,customer]:
            self.call('/api/tickets/{ticket_id}/read',ticket_id=ticket['id'],account=reader)
        cursor=core.list_events(account=self.tech2,pool=self.pool)['cursor']
        self.call('/api/tickets/{ticket_id}/assignment',ticket_id=ticket['id'],body=m.AssignmentInput(action='transfer',technician_id=self.tech2['id'],note='İnceleme için aktarım'),staff=self.tech1)
        viewed=core.get_ticket(ticket['id'],customer,self.pool)
        self.assertEqual(viewed['assigned_to'],self.tech1['id'])
        self.assertEqual(viewed['messages'],[])
        self.assertNotIn('technician_notifications',viewed)
        self.assertEqual(core.get_ticket(ticket['id'],self.tech2,self.pool)['technician_notifications'][0]['message'],'İnceleme için aktarım')
        self.assertEqual(core.get_ticket(ticket['id'],self.admin,self.pool)['technician_notifications'],[])
        received=core.list_events(after=cursor,account=self.tech2,pool=self.pool)['events']
        self.assertEqual([(e['kind'],e['message'],e['recipient_id']) for e in received],[('technician_notification','İnceleme için aktarım',self.tech2['id'])])
        for other in [self.tech1,self.admin,customer]:
            self.assertEqual(core.list_events(after=cursor,account=other,pool=self.pool)['events'],[])
            self.assertEqual(core.list_tickets(other,self.pool)[0]['unread_count'],0)
        self.assertEqual(core.list_tickets(self.tech2,self.pool)[0]['unread_count'],1)
        self.call('/api/tickets/{ticket_id}/read',ticket_id=ticket['id'],account=self.tech2)
        self.assertEqual(core.list_tickets(self.tech2,self.pool)[0]['unread_count'],0)
        core.add_message(ticket['id'],core.MessageInput(message='İşlem yapmaya devam ediyorum'),self.tech1,self.pool)
        normal=core.list_events(after=received[0]['id'],account=customer,pool=self.pool)['events']
        self.assertEqual([e['kind'] for e in normal],['message'])
        self.call('/api/tickets/{ticket_id}/assignment',ticket_id=ticket['id'],body=m.AssignmentInput(action='release'),staff=self.tech1)
        self.assertIsNone(core.get_ticket(ticket['id'],customer,self.pool)['assigned_to'])
        core.update_ticket_status(ticket['id'],core.StatusInput(status='closed',note='Müşteri talebiyle iptal'),self.tech1,self.pool)
        history=self.call('/api/tickets/{ticket_id}/history',ticket_id=ticket['id'],account=self.tech1)
        self.assertTrue(any(h['action']=='ticket_technician_notified' for h in history))
        core.add_message(ticket['id'],core.MessageInput(message='Arşiv açıklaması'),self.tech1,self.pool)
        self.call('/api/admin/accounts/{account_id}/manage',account_id=self.tech1['id'],body=m.AccountActionInput(action='delete',confirmation='Birinci'),admin=self.admin)
        self.assertEqual(core.get_ticket(ticket['id'],self.admin,self.pool)['messages'][-1]['sender_name'],'Birinci')

    def test_customer_sees_only_active_tickets_and_cannot_read_operation_history(self):
        _,_,customer=self.license()
        tickets=[core.create_ticket(core.TicketInput(category='Sistem',title='Destek isteği',description='Ayrıntı'),customer,self.pool) for _ in range(3)]
        core.update_ticket_status(tickets[1]['id'],core.StatusInput(status='resolved'),self.tech1,self.pool)
        core.update_ticket_status(tickets[2]['id'],core.StatusInput(status='closed',note='İptal edildi'),self.tech1,self.pool)
        self.assertEqual([t['id'] for t in core.list_tickets(customer,self.pool)],[tickets[0]['id']])
        self.assertEqual(core.get_ticket(tickets[0]['id'],customer,self.pool)['id'],tickets[0]['id'])
        core.add_message(tickets[0]['id'],core.MessageInput(message='Aktif talebime ek bilgi'),customer,self.pool)
        self.assertEqual(core.get_ticket(tickets[0]['id'],customer,self.pool)['messages'][0]['sender_id'],customer['id'])
        self.assertEqual(self.call('/api/tickets/{ticket_id}/history',ticket_id=tickets[0]['id'],account=customer),[])
        for ticket in tickets[1:]:
            for action in [lambda:core.get_ticket(ticket['id'],customer,self.pool),
                           lambda:core.add_message(ticket['id'],core.MessageInput(message='Kapalı talebe yazma'),customer,self.pool),
                           lambda:self.call('/api/tickets/{ticket_id}/read',ticket_id=ticket['id'],account=customer)]:
                with self.assertRaises(HTTPException) as closed_error:
                    action()
                self.assertEqual(closed_error.exception.status_code,404)
        self.assertEqual([e['kind'] for e in core.list_events(after=0,account=customer,pool=self.pool)['events']],['ticket_status','ticket_status'])
        self.assertEqual(len(core.list_tickets(self.admin,self.pool)),3)

    def test_free_connection_limit_cooldown_and_premium_parallel_sessions(self):
        a=m.LeaseInput(device_id='123456',session_id=str(uuid4()),peer_id='654321')
        result=self.call('/api/connections/start',body=a,request=self.request)
        self.assertFalse(result['premium'])
        self.assertLessEqual((result['expires_at']-datetime.now(timezone.utc)).total_seconds(),300)
        b=m.LeaseInput(device_id='123456',session_id=str(uuid4()),peer_id='654322')
        with self.assertRaises(HTTPException) as e:
            self.call('/api/connections/start',body=b,request=self.request)
        self.assertEqual(e.exception.status_code,429)
        with self.pool.connection() as conn:
            conn.execute("UPDATE connection_leases SET expires_at=now()-interval '1 second',cooldown_until=now()+interval '59 seconds'")
            conn.commit()
        with self.assertRaises(HTTPException) as e:
            self.call('/api/connections/start',body=b,request=self.request)
        self.assertEqual(e.exception.status_code,429)
        self.assertLessEqual(e.exception.detail['retry_after'],60)
        _,login,customer=self.license()
        req=Request({'type':'http','headers':[(b'authorization',('Bearer '+login['access_token']).encode())],'client':('127.0.0.1',1234)})
        for peer in ['777777','888888']:
            r=self.call('/api/connections/start',body=m.LeaseInput(device_id='123456',session_id=str(uuid4()),peer_id=peer),request=req)
            self.assertTrue(r['premium'])

    def test_usage_only_license_keeps_unlimited_connections_but_cannot_use_support(self):
        support,_,supported=self.license()
        ticket=core.create_ticket(core.TicketInput(category='Sistem',title='Destek isteği',description='Ayrıntı'),supported,self.pool)
        usage=self.call('/api/admin/firm-licenses',body=m.FirmLicenseInput(account_id=supported['id']),admin=self.admin)
        login=self.call('/api/auth/license',body=m.LicenseCodeInput(license_code=usage['code'],device_id='123456'),request=self.request)
        customer=core.current_account(HTTPAuthorizationCredentials(scheme='Bearer',credentials=login['access_token']),self.pool)
        profile=core.me(customer,self.pool)
        self.assertTrue(profile['licensed'])
        self.assertFalse(profile['support_enabled'])
        for action in [lambda:core.list_tickets(customer,self.pool),lambda:core.get_ticket(ticket['id'],customer,self.pool),
                       lambda:core.list_events(account=customer,pool=self.pool),
                       lambda:core.add_message(ticket['id'],core.MessageInput(message='Yetkisiz mesaj'),customer,self.pool),
                       lambda:core.create_ticket(core.TicketInput(category='Sistem',title='Yeni kayıt',description='Ayrıntı'),customer,self.pool),
                       lambda:self.call('/api/tickets/{ticket_id}/read',ticket_id=ticket['id'],account=customer),
                       lambda:self.call('/api/tickets/{ticket_id}/history',ticket_id=ticket['id'],account=customer)]:
            with self.assertRaises(HTTPException) as denied:
                action()
            self.assertEqual(denied.exception.status_code,403)
        req=Request({'type':'http','headers':[(b'authorization',('Bearer '+login['access_token']).encode())],'client':('127.0.0.1',1234)})
        for peer in ['777777','888888']:
            self.assertTrue(self.call('/api/connections/start',body=m.LeaseInput(device_id='123456',session_id=str(uuid4()),peer_id=peer),request=req)['premium'])
        self.call('/api/admin/licenses/{license_id}/manage',license_id=support['id'],body=m.LicenseActionInput(action='configure',support_enabled=False),admin=self.admin)
        self.call('/api/admin/firm-licenses',body=m.FirmLicenseInput(account_id=supported['id'],support_enabled=True),admin=self.admin)
        self.assertEqual(core.get_ticket(ticket['id'],self.admin,self.pool)['id'],ticket['id'])
        with self.assertRaises(HTTPException) as denied_connection:
            core.request_ticket_connection(ticket['id'],self.tech1,self.pool)
        self.assertEqual(denied_connection.exception.status_code,403)

    def test_license_device_limit_inventory_and_revocation(self):
        row,login,customer=self.license()
        inventory=self.call('/api/admin/licenses/{license_id}/devices',license_id=row['id'],admin=self.admin)
        self.assertEqual([d['device_id'] for d in inventory],['123456'])
        with self.assertRaises(HTTPException) as capped:
            self.call('/api/auth/license',body=m.LicenseCodeInput(license_code=row['code'],device_id='654321'),request=self.request)
        self.assertEqual(capped.exception.status_code,409)
        self.call('/api/admin/licenses/{license_id}/devices/{device_id}/manage',license_id=row['id'],device_id='123456',body=m.DeviceActionInput(action='revoke'),admin=self.admin)
        with self.assertRaises(HTTPException) as old_session:
            core.current_account(HTTPAuthorizationCredentials(scheme='Bearer',credentials=login['access_token']),self.pool)
        self.assertEqual(old_session.exception.status_code,401)
        with self.assertRaises(HTTPException) as blocked_device:
            self.call('/api/auth/license',body=m.LicenseCodeInput(license_code=row['code'],device_id='123456'),request=self.request)
        self.assertEqual(blocked_device.exception.status_code,403)
        second=self.call('/api/auth/license',body=m.LicenseCodeInput(license_code=row['code'],device_id='654321',device_name='Muhasebe',app_version='1.16.0'),request=self.request)
        with self.assertRaises(HTTPException) as restore_full:
            self.call('/api/admin/licenses/{license_id}/devices/{device_id}/manage',license_id=row['id'],device_id='123456',body=m.DeviceActionInput(action='restore'),admin=self.admin)
        self.assertEqual(restore_full.exception.status_code,409)
        self.call('/api/admin/licenses/{license_id}/devices/{device_id}/manage',license_id=row['id'],device_id='654321',body=m.DeviceActionInput(action='revoke'),admin=self.admin)
        self.call('/api/admin/licenses/{license_id}/devices/{device_id}/manage',license_id=row['id'],device_id='123456',body=m.DeviceActionInput(action='restore'),admin=self.admin)
        with self.assertRaises(HTTPException):
            core.current_account(HTTPAuthorizationCredentials(scheme='Bearer',credentials=login['access_token']),self.pool)
        fresh=self.call('/api/auth/license',body=m.LicenseCodeInput(license_code=row['code'],device_id='123456'),request=self.request)
        self.assertTrue(fresh['account']['licensed'])
        inventory=self.call('/api/admin/licenses/{license_id}/devices',license_id=row['id'],admin=self.admin)
        other=next(d for d in inventory if d['device_id']=='654321')
        self.assertEqual((other['device_name'],other['app_version']),('Muhasebe','1.16.0'))
        self.assertIsNotNone(other['revoked_at'])
        self.call('/api/admin/licenses/{license_id}/manage',license_id=row['id'],body=m.LicenseActionInput(action='configure',device_limit=0),admin=self.admin)
        legacy=self.call('/api/auth/license',body=m.LicenseCodeInput(license_code=row['code']),request=self.request)
        legacy_account=core.current_account(HTTPAuthorizationCredentials(scheme='Bearer',credentials=legacy['access_token']),self.pool)
        self.assertTrue(legacy_account['licensed'])
        self.assertTrue(legacy_account['support_enabled'])
        self.assertIsNone(legacy_account['device_id'])
        old_ticket=core.create_ticket(core.TicketInput(category='Sistem',title='Eski istemci',description='Destek',device_id='123456'),legacy_account,self.pool)
        self.assertEqual(old_ticket['device_id'],'123456')
        req=Request({'type':'http','headers':[(b'authorization',('Bearer '+legacy['access_token']).encode())],'client':('127.0.0.1',1234)})
        lease=m.LeaseInput(device_id='123456',session_id=str(uuid4()),peer_id='777777')
        self.call('/api/connections/start',body=lease,request=req)
        with self.pool.connection() as conn:
            conn.execute('UPDATE connection_leases SET license_id=NULL WHERE session_id=%s',(lease.session_id,))
            conn.commit()
        self.assertTrue(self.call('/api/connections/start',body=lease,request=req)['premium'])
        self.call('/api/admin/licenses/{license_id}/manage',license_id=row['id'],body=m.LicenseActionInput(action='configure',device_limit=1),admin=self.admin)
        with self.assertRaises(HTTPException) as old_limited:
            core.current_account(HTTPAuthorizationCredentials(scheme='Bearer',credentials=legacy['access_token']),self.pool)
        self.assertEqual(old_limited.exception.status_code,401)
        with self.assertRaises(HTTPException) as no_device:
            self.call('/api/auth/license',body=m.LicenseCodeInput(license_code=row['code']),request=self.request)
        self.assertEqual(no_device.exception.status_code,422)

    def test_trial_expiry_and_file_children_share_the_parent_policy(self):
        with self.assertRaises(HTTPException) as no_expiry:
            self.call('/api/admin/firm-licenses',body=m.FirmLicenseInput(display_name='Deneme',license_kind='trial'),admin=self.admin)
        self.assertEqual(no_expiry.exception.status_code,422)
        trial=self.call('/api/admin/firm-licenses',body=m.FirmLicenseInput(display_name='Deneme',license_kind='trial',duration_days=7),admin=self.admin)
        logged=self.call('/api/auth/license',body=m.LicenseCodeInput(license_code=trial['code'],device_id='123456'),request=self.request)
        self.assertEqual(logged['account']['license_kind'],'trial')
        with self.pool.connection() as conn:
            conn.execute("UPDATE licenses SET expires_at=now()-interval '1 second' WHERE id=%s",(trial['id'],))
            conn.commit()
        with self.assertRaises(HTTPException) as expired:
            core.current_account(HTTPAuthorizationCredentials(scheme='Bearer',credentials=logged['access_token']),self.pool)
        self.assertEqual(expired.exception.status_code,401)
        parent=m.LeaseInput(device_id='123456',session_id=str(uuid4()),peer_id='654321')
        root=self.call('/api/connections/start',body=parent,request=self.request)
        child=m.LeaseInput(device_id='123456',session_id=str(uuid4()),peer_id='654321',parent_session_id=parent.session_id)
        file=self.call('/api/connections/start',body=child,request=self.request)
        permit=json.loads(base64.b64decode(file['permit'].split('.')[0]))
        self.assertEqual((permit['session_id'],permit['policy_session_id']),(child.session_id,parent.session_id))
        self.assertEqual(file['expires_at'],root['expires_at'])
        self.assertFalse(file['premium'])
        for wrong in [m.LeaseInput(device_id='123456',session_id=str(uuid4()),peer_id='111111',parent_session_id=parent.session_id),
                      m.LeaseInput(device_id='654321',session_id=str(uuid4()),peer_id='654321',parent_session_id=parent.session_id)]:
            with self.assertRaises(HTTPException) as mismatched:
                self.call('/api/connections/start',body=wrong,request=self.request)
            self.assertEqual(mismatched.exception.status_code,409)
        self.call('/api/connections/{session_id}/end',session_id=child.session_id,request=self.request)
        self.assertFalse(self.call('/api/connections/start',body=parent,request=self.request)['premium'])
        self.call('/api/connections/{session_id}/end',session_id=parent.session_id,request=self.request)
        with self.assertRaises(HTTPException) as ended:
            self.call('/api/connections/start',body=child,request=self.request)
        self.assertEqual(ended.exception.status_code,409)
