import base64
from contextlib import closing
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import sqlite3
import tempfile
import threading
import time
import unittest

from ai_server import AccessError, Entitlement, create_app


class AIServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.database = str(Path(self.temp.name) / 'ai.sqlite3')
        self.invocations = []

        def verify(proof):
            if proof != 'verified-proof':
                raise AccessError('Invalid proof.', 401)
            return Entitlement('subscriber', 'billing-period', time.time() + 3600)

        def provider(body, vision, config):
            self.invocations.append((body, vision))
            return 'The resistor and capacitor form an RC filter.'

        self.settings = {'TESTING': True, 'AI_DB': self.database, 'MONTHLY_CALLS': 2}
        self.app = create_app(self.settings, subscription_verifier=verify, provider=provider)
        self.client = self.app.test_client()
        self.body = {'context': json.dumps({'schema': 'circuitstudio-assistant-v1'}), 'question': 'Explain the circuit.', 'language': 'English'}

    def tearDown(self):
        self.temp.cleanup()

    def headers(self, nonce='request-key-000000001'):
        return {'Authorization': 'StoreKit verified-proof', 'Idempotency-Key': nonce}

    def used(self):
        with closing(sqlite3.connect(self.database)) as connection:
            row = connection.execute('SELECT used FROM usage').fetchone()
            return row[0] if row else 0

    def test_subscription_required_and_invalid_input_costs_nothing(self):
        self.assertEqual(self.client.post('/explain', json=self.body).status_code, 401)
        self.assertEqual(self.client.post('/explain', json=self.body, headers={'Authorization': 'StoreKit fake', 'Idempotency-Key': 'request-key-000000001'}).status_code, 401)
        invalid = dict(self.body, context='not-json')
        self.assertEqual(self.client.post('/explain', json=invalid, headers=self.headers()).status_code, 400)
        self.assertEqual(self.used(), 0)
        self.assertEqual(self.invocations, [])

    def test_idempotency_and_quota(self):
        first = self.client.post('/explain', json=self.body, headers=self.headers())
        second = self.client.post('/explain', json=self.body, headers=self.headers())
        self.assertEqual(first.status_code, 200)
        self.assertEqual(second.json['answer'], first.json['answer'])
        self.assertEqual(len(self.invocations), 1)
        self.assertEqual(self.used(), 1)
        changed = dict(self.body, question='Different question')
        self.assertEqual(self.client.post('/explain', json=changed, headers=self.headers()).status_code, 409)
        self.assertEqual(self.client.post('/explain', json=self.body, headers=self.headers('request-key-000000002')).status_code, 200)
        self.assertEqual(self.client.post('/explain', json=self.body, headers=self.headers('request-key-000000003')).status_code, 429)
        self.assertEqual(self.used(), 2)

    def test_failure_restores_quota(self):
        def broken(*args):
            raise AccessError('Upstream failed', 502)
        app = create_app(self.settings, subscription_verifier=lambda _: Entitlement('subscriber', 'period', time.time() + 3600), provider=broken)
        self.assertEqual(app.test_client().post('/explain', json=self.body, headers=self.headers()).status_code, 502)
        self.assertEqual(self.used(), 0)

    def test_expired_subscription_and_unconfigured_verifier_fail_closed(self):
        expired = create_app(self.settings, subscription_verifier=lambda _: Entitlement('subscriber', 'period', 1), provider=lambda *_: 'answer')
        self.assertEqual(expired.test_client().post('/explain', json=self.body, headers=self.headers()).status_code, 403)
        unconfigured = create_app(self.settings)
        self.assertEqual(unconfigured.test_client().post('/explain', json=self.body, headers=self.headers()).status_code, 503)
        self.assertEqual(self.used(), 0)

    def test_image_is_sent_as_image_not_ocr_text(self):
        body = {'imageBase64': base64.b64encode(b'\xff\xd8\xfftest').decode(), 'question': 'Explain this image.', 'language': '中文'}
        response = self.client.post('/recognize', json=body, headers=self.headers())
        self.assertEqual(response.status_code, 200)
        submitted, vision = self.invocations[0]
        self.assertTrue(vision)
        self.assertTrue(submitted['imageDataURL'].startswith('data:image/jpeg;base64,'))
        body['imageBase64'] = base64.b64encode(b'not an image').decode()
        self.assertEqual(self.client.post('/recognize', json=body, headers=self.headers('request-key-000000002')).status_code, 400)
        self.assertEqual(self.used(), 1)

    def test_parallel_requests_cannot_exceed_quota(self):
        started = threading.Event(); release = threading.Event()
        def slow(*args):
            started.set(); release.wait(5); return 'answer'
        app = create_app(self.settings, subscription_verifier=lambda _: Entitlement('subscriber', 'period', time.time() + 3600), provider=slow)
        with ThreadPoolExecutor(max_workers=2) as pool:
            future = pool.submit(lambda: app.test_client().post('/explain', json=self.body, headers=self.headers()))
            self.assertTrue(started.wait(5))
            second = app.test_client().post('/explain', json=self.body, headers=self.headers('request-key-000000002'))
            self.assertEqual(second.status_code, 409)
            release.set()
            self.assertEqual(future.result().status_code, 200)
        self.assertEqual(self.used(), 1)

    def test_abandoned_worker_restores_reserved_call(self):
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute('INSERT INTO usage VALUES (?,?,?)', ('subscriber', 'billing-period', 1))
            connection.execute('INSERT INTO requests VALUES (?,?,?,?,?,?,?)', ('subscriber', 'old-request', 'billing-period', 'hash', 'pending', None, time.time() - 300))
        self.assertEqual(self.client.post('/explain', json=self.body, headers=self.headers()).status_code, 200)
        self.assertEqual(self.used(), 1)


if __name__ == '__main__':
    unittest.main()
