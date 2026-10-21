import os
import unittest
from datetime import datetime, timezone
from uuid import uuid4
from unittest.mock import patch

from fastapi import HTTPException
from fastapi.security import HTTPAuthorizationCredentials
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool
from starlette.requests import Request
from app import main as core, management as m


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
        row=self.call('/api/admin/firm-licenses',body=m.FirmLicenseInput(display_name='Hünkar',duration_days=30),admin=self.admin)
        result=self.call('/api/auth/license',body=m.LicenseCodeInput(license_code=row['code']),request=self.request)
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
            self.call('/api/auth/license',body=m.LicenseCodeInput(license_code=row['code']),request=self.request)
        fresh=self.call('/api/auth/license',body=m.LicenseCodeInput(license_code=new['code']),request=self.request)
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
        self.assertEqual(core.list_events(after=0,account=customer,pool=self.pool)['events'],[])
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
