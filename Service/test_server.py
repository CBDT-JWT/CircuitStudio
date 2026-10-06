import json
from pathlib import Path
import secrets
import sqlite3
import tempfile
import unittest
from server import create_app

class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        (root/'releases').mkdir()
        self.payload = b'installer verification bytes' * 12000
        (root/'releases/CircuitStudio-1.2.0-universal.dmg').write_bytes(self.payload)
        (root/'releases/release.json').write_text(json.dumps({'file':'CircuitStudio-1.2.0-universal.dmg','version':'1.2.0','bytes':len(self.payload)}))
        self.database = root/'contacts.sqlite3'
        self.app = create_app({'TESTING':True,'CONTACT_DB':str(self.database),'RELEASE_DIR':str(root/'releases'),'SITE_ORIGIN':'https://test.invalid','RATE_SALT':'test'})
        self.client = self.app.test_client()

    def issue(self, email='reader@example.com'):
        return self.client.post('/api/request-download',json={'email':email},headers={'Origin':'https://test.invalid'})

    def count(self):
        return self.client.get('/api/stats').json['downloads']

    def test_valid_download_and_private_registry(self):
        issued=self.issue(' Reader@Example.COM ')
        self.assertEqual(issued.status_code,200)
        self.assertEqual(self.count(),0)
        response=self.client.get('/'+issued.json['downloadURL'],buffered=True)
        self.assertEqual(response.data,self.payload)
        self.assertIn('attachment',response.headers['Content-Disposition'])
        self.assertEqual(self.count(),1)
        self.assertNotIn('reader@example.com',str(self.client.get('/api/stats').json))
        with sqlite3.connect(self.database) as connection:
            self.assertEqual(connection.execute('SELECT email FROM contacts').fetchone()[0],'reader@example.com')

    def test_repeated_email_counts_once(self):
        for email in ['Reader@example.com','reader@example.com']:
            issued=self.issue(email)
            self.client.get('/'+issued.json['downloadURL'],buffered=True)
        self.assertEqual(self.count(),1)

    def test_second_email_increases_count(self):
        for email in ['one@example.com','two@example.com']:
            issued=self.issue(email)
            self.client.get('/'+issued.json['downloadURL'],buffered=True)
        self.assertEqual(self.count(),2)

    def test_rejects_invalid_email_and_cross_origin(self):
        for email in ['no-email','a@b','a@example.com\nInjected: header','<script>@example.com']:
            self.assertEqual(self.issue(email).status_code,400)
        self.assertEqual(self.client.post('/api/request-download',json={'email':'a@example.com'},headers={'Origin':'https://other.invalid'}).status_code,403)
        self.assertEqual(self.count(),0)

    def test_tokens_expire_and_cannot_be_guessed(self):
        issued=self.issue()
        with sqlite3.connect(self.database) as connection:
            connection.execute('UPDATE tokens SET expires_at=0'); connection.commit()
        self.assertEqual(self.client.get('/'+issued.json['downloadURL']).status_code,410)
        self.assertEqual(self.client.get('/api/download/'+secrets.token_urlsafe(32)).status_code,410)
        self.assertEqual(self.client.get('/api/download/short').status_code,404)

    def test_aborted_stream_does_not_count(self):
        issued=self.issue()
        response=self.client.get('/'+issued.json['downloadURL'],buffered=False)
        next(response.response)
        response.close()
        self.assertEqual(self.count(),0)

    def test_rate_limit_and_honeypot(self):
        self.app.config['REQUESTS_PER_HOUR']=1
        self.assertEqual(self.issue().status_code,200)
        self.assertEqual(self.issue('two@example.com').status_code,429)
        self.assertEqual(self.client.post('/api/request-download',json={'email':'three@example.com','company':'bot'},headers={'Origin':'https://test.invalid'}).status_code,400)
        self.assertEqual(self.count(),0)

if __name__=='__main__': unittest.main()
