import hashlib
import json
from pathlib import Path
import re
import tempfile
import unittest

from werkzeug.security import generate_password_hash
from ai_server import create_app

class AdminTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.calls=[]
        def provider(body,vision,config):
            self.calls.append(config)
            return 'RC 低通滤波器；请用 AC 分析确认带宽。'
        self.app=create_app({'TESTING':True,'AI_DB':str(Path(self.temp.name)/'usage.sqlite3'),'ADMIN_PASSWORD_HASH':generate_password_hash('test-only-password')},provider=provider)
        self.client=self.app.test_client()
    def tearDown(self): self.temp.cleanup()
    def csrf(self):
        with self.client.session_transaction() as session: return session['csrf']
    def login(self):
        self.client.get('/admin/login')
        response=self.client.post('/admin/login',data={'csrf':self.csrf(),'password':'test-only-password'})
        self.assertEqual(response.status_code,302)
    def issue(self,calls=2):
        response=self.client.post('/admin/tokens',data={'csrf':self.csrf(),'label':'My Mac','calls':calls})
        self.assertEqual(response.status_code,200)
        return re.search(r'<code>(cs_[A-Za-z0-9_-]+)</code>',response.text)[1]
    def ask(self,token,nonce):
        return self.client.post('/explain',json={'context':json.dumps({'schema':'circuitstudio-assistant-v1'}),'question':'解读电路','language':'中文'},headers={'Authorization':'Bearer '+token,'Idempotency-Key':'test-relay-request-'+nonce})
    def test_login_required_csrf_and_no_provider_key_leak(self):
        self.assertEqual(self.client.get('/admin').status_code,302)
        self.assertEqual(self.client.post('/admin/settings',data={'api_key':'sk-test'}).status_code,302)
        self.login()
        self.assertEqual(self.client.post('/admin/settings',data={'api_key':'sk-test'}).status_code,403)
        self.assertEqual(self.client.post('/admin/settings',data={'csrf':self.csrf(),'api_key':'sk-test-only-key','model':'deepseek-flash'}).status_code,302)
        page=self.client.get('/admin')
        self.assertIn('已配置',page.text)
        self.assertNotIn('sk-test-only-key',page.text)
        self.assertEqual(page.headers['Cache-Control'],'no-store')
        self.assertIn("frame-ancestors 'none'",page.headers['Content-Security-Policy'])
        token=self.issue(); self.assertEqual(self.ask(token,'0001').status_code,200)
        self.assertEqual(self.calls[0]['DEEPSEEK_API_KEY'],'sk-test-only-key')
    def test_relay_quota_idempotency_and_revoke(self):
        self.login(); token=self.issue()
        self.assertEqual(self.ask(token,'0001').status_code,200)
        self.assertEqual(self.ask(token,'0001').status_code,200)
        self.assertEqual(len(self.calls),1)
        self.assertEqual(self.ask(token,'0002').status_code,200)
        self.assertEqual(self.ask(token,'0003').status_code,429)
        import sqlite3
        with sqlite3.connect(self.app.config['AI_DB']) as db:
            row=db.execute('SELECT id,digest FROM relay_tokens').fetchone()
            self.assertEqual(row[1],hashlib.sha256(token.encode()).hexdigest())
        self.client.post('/admin/tokens/revoke',data={'csrf':self.csrf(),'id':row[0]})
        self.assertEqual(self.ask(token,'0004').status_code,401)
    def test_admin_rate_limit_and_logout(self):
        self.client.get('/admin/login')
        for _ in range(8): self.client.post('/admin/login',data={'csrf':self.csrf(),'password':'wrong'})
        self.assertEqual(self.client.post('/admin/login',data={'csrf':self.csrf(),'password':'test-only-password'}).status_code,429)
    def test_prefix_aware_forms_and_invalid_model(self):
        self.login()
        response=self.client.get('/admin',headers={'X-Forwarded-Prefix':'/api/circuit-ai'})
        self.assertIn('/api/circuit-ai/admin/settings',response.text)
        response=self.client.post('/admin/settings',data={'csrf':self.csrf(),'model':'untrusted-model'})
        self.assertEqual(response.status_code,400)

class PurchaseActivationTests(unittest.TestCase):
    def test_verified_purchase_activates_without_access_code_and_refund_invalidates(self):
        from ai_server import Entitlement, AccessError
        import time
        class AppleEvidence:
            def __call__(self,proof):
                if proof!='valid-apple-proof': raise AccessError('Invalid proof',401)
                return Entitlement('apple-original-id','apple-billing-period',time.time()+3600,200,'apple-transaction-id')
            def notification(self,signed):
                if signed=='signed-refund': return 'apple-transaction-id',200,True
                if signed=='older-reversal': return 'apple-transaction-id',100,False
                if signed=='newer-reversal': return 'apple-transaction-id',300,False
                raise AccessError('Invalid signature',401)
        with tempfile.TemporaryDirectory() as folder:
            app=create_app({'TESTING':True,'AI_DB':str(Path(folder)/'billing.sqlite3')},subscription_verifier=AppleEvidence(),provider=lambda *_:'Verified explanation')
            client=app.test_client()
            auth={'Authorization':'StoreKit valid-apple-proof'}
            self.assertEqual(client.get('/entitlement',headers=auth).json['remaining'],200)
            self.assertEqual(client.post('/apple/notifications',json={'signedPayload':'fake'}).status_code,401)
            self.assertEqual(client.post('/apple/notifications',json={'signedPayload':'signed-refund'}).status_code,200)
            self.assertEqual(client.get('/entitlement',headers=auth).status_code,403)
            client.post('/apple/notifications',json={'signedPayload':'older-reversal'})
            self.assertEqual(client.get('/entitlement',headers=auth).status_code,403)
            client.post('/apple/notifications',json={'signedPayload':'newer-reversal'})
            self.assertEqual(client.get('/entitlement',headers=auth).status_code,200)
            self.assertEqual(client.get('/entitlement',headers={'Authorization':'StoreKit fake'}).status_code,401)
