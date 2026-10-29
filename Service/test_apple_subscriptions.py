import base64
import json
from pathlib import Path
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from appstoreserverlibrary.models.Environment import Environment
from appstoreserverlibrary.models.Status import Status
from appstoreserverlibrary.signed_data_verifier import VerificationException, VerificationStatus

from ai_server import AccessError, AppleSubscriptionVerifier, create_app


class AppleEnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        # Routing tests replace Apple's verifier, not the gateway's policy.
        (root / 'root.cer').write_bytes(b'test-root')
        self.config = dict(APPLE_ENVIRONMENT='Production', APPLE_ENVIRONMENTS='Production,Sandbox',
                           APPLE_ROOT_CERTS=str(root), APPLE_APP_ID='6819344214',
                           APPLE_BUNDLE_ID='com.circuitstudio.app', PRODUCT_IDS=['com.circuitstudio.app.ai.monthly'],
                           MONTHLY_CALLS=200, APPLE_KEY_PATH='', APPLE_KEY_ID='', APPLE_ISSUER_ID='')
        self.instances = {}
        self.factory = patch('appstoreserverlibrary.signed_data_verifier.SignedDataVerifier', side_effect=self.make_verifier)
        self.factory.start()
        self.addCleanup(self.factory.stop)

    def proof(self, **changes):
        values = dict(productId='com.circuitstudio.app.ai.monthly', originalTransactionId='same-original',
                      transactionId='same-transaction', purchaseDate=1000, expiresDate=int((time.time()+3600)*1000),
                      revocationDate=None)
        values.update(changes)
        return SimpleNamespace(**values)

    def make_verifier(self, roots, online, environment, bundle_id, app_id):
        self.assertTrue(online)
        self.assertEqual(bundle_id, 'com.circuitstudio.app')
        self.assertEqual(app_id, 6819344214)
        verifier = Mock()
        def transaction(signed):
            failures = {'tampered': VerificationStatus.VERIFICATION_FAILURE,
                        'wrong-app': VerificationStatus.INVALID_APP_IDENTIFIER,
                        'xcode-local': VerificationStatus.INVALID_CERTIFICATE,
                        'ocsp-unavailable': VerificationStatus.RETRYABLE_VERIFICATION_FAILURE}
            if signed in failures:
                raise VerificationException(failures[signed])
            name = 'Sandbox' if signed.startswith('sandbox') else 'Production'
            if name != environment.value:
                raise VerificationException(VerificationStatus.INVALID_ENVIRONMENT)
            changes = {}
            if signed.endswith('expired'): changes['expiresDate'] = 1
            if signed.endswith('revoked'): changes['revocationDate'] = 1000
            if signed.endswith('wrong-product'): changes['productId'] = 'other.app.monthly'
            return self.proof(**changes)
        def notification(signed):
            name = 'Sandbox' if signed.startswith('sandbox') else 'Production'
            if name != environment.value:
                raise VerificationException(VerificationStatus.INVALID_ENVIRONMENT)
            info = 'production-valid' if signed.endswith('mixed') else name.lower()+'-valid'
            return SimpleNamespace(data=SimpleNamespace(signedTransactionInfo=info),
                                   notificationType=SimpleNamespace(value='REFUND'), signedDate=2000)
        verifier.verify_and_decode_signed_transaction.side_effect = transaction
        verifier.verify_and_decode_notification.side_effect = notification
        self.instances[environment.value] = verifier
        return verifier

    def test_production_preserves_existing_quota_and_testflight_activates_separately(self):
        verifier = AppleSubscriptionVerifier(self.config)
        production = verifier('production-valid')
        sandbox = verifier('sandbox-valid')
        self.assertEqual(production.subject, 'same-original')
        self.assertEqual(production.transaction, 'same-transaction')
        self.assertEqual(sandbox.subject, 'sandbox:same-original')
        self.assertEqual(sandbox.transaction, 'sandbox:same-transaction')
        self.assertEqual(sandbox.calls, 200)

    def test_fallback_only_accepts_configured_environments(self):
        verifier = AppleSubscriptionVerifier(dict(self.config, APPLE_ENVIRONMENTS=''))
        with self.assertRaises(AccessError) as denied:
            verifier('sandbox-valid')
        self.assertEqual(denied.exception.status, 401)
        for name in ['Xcode', 'LocalTesting', 'Production,Unknown', 'Sandbox,']:
            with self.assertRaises(ValueError):
                AppleSubscriptionVerifier(dict(self.config, APPLE_ENVIRONMENTS=name))

    def test_invalid_signature_app_or_local_testing_never_falls_back(self):
        verifier = AppleSubscriptionVerifier(self.config)
        for signed in ['tampered', 'wrong-app', 'xcode-local']:
            with self.assertRaises(AccessError) as denied:
                verifier(signed)
            self.assertEqual(denied.exception.status, 401)
        self.instances['Sandbox'].verify_and_decode_signed_transaction.assert_not_called()

    def test_expired_revoked_and_other_product_purchases_cannot_activate(self):
        verifier = AppleSubscriptionVerifier(self.config)
        for environment in ['production', 'sandbox']:
            for suffix in ['expired', 'revoked', 'wrong-product']:
                with self.assertRaises(AccessError) as denied:
                    verifier(environment+'-'+suffix)
                self.assertEqual(denied.exception.status, 403)

    def test_certificate_service_outage_is_retryable_without_accepting_proof(self):
        verifier = AppleSubscriptionVerifier(self.config)
        with self.assertRaises(AccessError) as denied:
            verifier('ocsp-unavailable')
        self.assertEqual(denied.exception.status, 503)
        self.instances['Sandbox'].verify_and_decode_signed_transaction.assert_not_called()

    def test_server_api_uses_the_verified_environment_and_rejects_cross_environment_status(self):
        key = Path(self.temp.name) / 'test-key.p8'
        key.write_bytes(b'test-only-key')
        clients = {}
        def client_factory(key_bytes, key_id, issuer, bundle_id, environment):
            client = Mock()
            clients[environment.value] = client
            return client
        settings = dict(self.config, APPLE_KEY_PATH=str(key), APPLE_KEY_ID='test-key', APPLE_ISSUER_ID='test-issuer')
        with patch('appstoreserverlibrary.api_client.AppStoreServerAPIClient', side_effect=client_factory):
            verifier = AppleSubscriptionVerifier(settings)
        item = SimpleNamespace(originalTransactionId='same-original', status=Status.ACTIVE,
                               signedTransactionInfo='sandbox-valid')
        clients['Sandbox'].get_all_subscription_statuses.return_value = SimpleNamespace(data=[SimpleNamespace(lastTransactions=[item])])
        self.assertEqual(verifier('sandbox-valid').subject, 'sandbox:same-original')
        clients['Production'].get_all_subscription_statuses.assert_not_called()
        item.signedTransactionInfo = 'production-valid'
        with self.assertRaises(AccessError) as denied:
            verifier('sandbox-valid')
        self.assertEqual(denied.exception.status, 401)

    def test_refund_notifications_are_isolated_and_cannot_mix_environments(self):
        verifier = AppleSubscriptionVerifier(self.config)
        self.assertEqual(verifier.notification('production-refund'), ('same-transaction', 2000, True))
        self.assertEqual(verifier.notification('sandbox-refund'), ('sandbox:same-transaction', 2000, True))
        with self.assertRaises(AccessError):
            verifier.notification('sandbox-mixed')

    def test_activation_and_refund_do_not_change_production_entitlement_or_quota(self):
        verifier = AppleSubscriptionVerifier(self.config)
        app = create_app(dict(self.config, TESTING=True, AI_DB=str(Path(self.temp.name)/'usage.sqlite3')),
                         subscription_verifier=verifier, provider=lambda *_: 'Verified test answer')
        client = app.test_client()
        production = {'Authorization':'StoreKit production-valid'}
        sandbox = {'Authorization':'StoreKit sandbox-valid'}
        self.assertEqual(client.get('/entitlement', headers=sandbox).status_code, 200)
        body = dict(context=json.dumps({'schema':'circuitstudio-assistant-v1'}), question='Explain.', language='English')
        self.assertEqual(client.post('/explain', json=body, headers=dict(sandbox, **{'Idempotency-Key':'sandbox-test-request-001'})).status_code, 200)
        self.assertEqual(client.get('/entitlement', headers=production).json['remaining'], 200)
        self.assertEqual(client.get('/entitlement', headers=sandbox).json['remaining'], 199)
        self.assertEqual(client.post('/apple/notifications', json={'signedPayload':'sandbox-refund'}).status_code, 200)
        self.assertEqual(client.get('/entitlement', headers=sandbox).status_code, 403)
        self.assertEqual(client.get('/entitlement', headers=production).status_code, 200)

    def test_real_apple_library_rejects_forged_sandbox_proof(self):
        self.factory.stop()
        verifier = AppleSubscriptionVerifier(self.config)
        def encode(value):
            return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip('=')
        signed = encode({'alg':'ES256','x5c':[]})+'.'+encode({'environment':'Sandbox', 'bundleId':'com.circuitstudio.app'})+'.invalid'
        with self.assertRaises(AccessError) as denied:
            verifier(signed)
        self.assertEqual(denied.exception.status, 401)


if __name__ == '__main__':
    unittest.main()
