import http.client
import json
import secrets
import ssl
import uuid

ca = ssl.create_default_context(cafile='deploy/forlan-support/support-ca.crt')
client = http.client.HTTPSConnection('95.70.196.174', 24443, context=ca, timeout=12)
device = str(900000000 + secrets.randbelow(99999999))

def post(path, body=None):
    payload = json.dumps(body).encode() if body is not None else b''
    client.request('POST', path, payload, {'Content-Type': 'application/json'})
    response = client.getresponse()
    data = response.read()
    return response.status, json.loads(data)

try:
    for attempt in range(2):
        session = str(uuid.uuid4())
        status, result = post('/api/connections/start', {'device_id': device, 'session_id': session, 'peer_id': '654321'})
        assert status == 200 and result['premium'] is False, ('start', attempt, status)
        status, result = post(f'/api/connections/{session}/end')
        assert status == 200 and result['ended'] is True, ('end', attempt, status)
    print('guest_early_disconnect_and_immediate_retry=passed')
finally:
    client.close()
