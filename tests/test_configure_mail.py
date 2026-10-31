"""Mail setup checks with a simulated SMTP connection; sends no email."""
from contextlib import redirect_stdout
import io
from pathlib import Path
import smtplib
import ssl
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'deploy/aws'))
import configure_mail as mail


class ConfigureMailTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = Path(self.directory.name) / '.env.aws'
        self.original = ('# Existing deployment\nDATA_MODE=fresh\nDB_NAME=sgi\nDB_USER=sgi\n'
                         'DB_PASSWORD=' + 'a' * 48 + '\nJWT_SECRET=' + 'b' * 64 + '\n'
                         'PUBLIC_URL=https://qa.sgi.example.edu.pe\nSITE_ADDRESS=qa.sgi.example.edu.pe\n'
                         'BIND_ADDRESS=0.0.0.0\nAPP_MAIL_MOCK=true\nAPP_MAIL_FROM=\n'
                         'SPRING_MAIL_HOST=localhost\nSPRING_MAIL_PORT=587\n'
                         'SPRING_MAIL_USERNAME=\nSPRING_MAIL_PASSWORD=\nCUSTOM_SETTING=keep-this\n')
        self.path.write_text(self.original)
        self.environment = patch.object(mail.config, 'ENV_FILE', self.path)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.addCleanup(self.directory.cleanup)

    def test_success_preserves_deployment_and_hides_credentials(self):
        output = io.StringIO()
        with patch('builtins.input', return_value=' QA.Sender@gmail.com '), \
             patch.object(mail.getpass, 'getpass', return_value='abcd efgh ijkl mnop'), \
             patch.object(mail, 'authenticate') as authenticate, redirect_stdout(output):
            mail.configure_gmail()
        values = mail.config.read_values()
        self.assertEqual(values['APP_MAIL_MOCK'], 'false')
        self.assertEqual(values['APP_MAIL_FROM'], 'qa.sender@gmail.com')
        self.assertEqual(values['SPRING_MAIL_USERNAME'], values['APP_MAIL_FROM'])
        self.assertEqual(values['SPRING_MAIL_PASSWORD'], 'abcdefghijklmnop')
        self.assertEqual(values['DB_PASSWORD'], 'a' * 48)
        self.assertEqual(values['JWT_SECRET'], 'b' * 64)
        self.assertEqual(values['PUBLIC_URL'], 'https://qa.sgi.example.edu.pe')
        self.assertEqual(values['CUSTOM_SETTING'], 'keep-this')
        self.assertIn('# Existing deployment', self.path.read_text())
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        authenticate.assert_called_once()
        self.assertNotIn('abcdefghijklmnop', output.getvalue())
        self.assertNotIn('a' * 48, output.getvalue())

    def test_authentication_failure_does_not_change_the_live_environment(self):
        with patch('builtins.input', return_value='qa.sender@gmail.com'), \
             patch.object(mail.getpass, 'getpass', return_value='abcdefghijklmnop'), \
             patch.object(mail, 'authenticate', side_effect=smtplib.SMTPAuthenticationError(535, b'rejected')):
            with self.assertRaises(smtplib.SMTPAuthenticationError):
                mail.configure_gmail()
        self.assertEqual(self.path.read_text(), self.original)
        self.assertEqual(list(self.path.parent.glob('.env.aws-mail-*')), [])

    def test_invalid_app_password_is_rejected_before_connecting(self):
        with patch('builtins.input', return_value='qa.sender@gmail.com'), \
             patch.object(mail.getpass, 'getpass', return_value='too-short'), \
             patch.object(mail, 'authenticate') as authenticate:
            with self.assertRaises(ValueError):
                mail.configure_gmail()
        authenticate.assert_not_called()
        self.assertEqual(self.path.read_text(), self.original)

    def test_other_provider_is_not_treated_as_personal_gmail(self):
        with self.assertRaises(ValueError):
            mail.gmail_values('someone@university.edu.pe', 'abcdefghijklmnop')

    def test_authentication_requires_verified_tls_and_sends_no_message(self):
        values = mail.gmail_values('qa.sender@gmail.com', 'abcdefghijklmnop')
        smtp = MagicMock()
        with patch.object(mail.smtplib, 'SMTP') as factory:
            factory.return_value.__enter__.return_value = smtp
            mail.authenticate(values)
        factory.assert_called_once_with('smtp.gmail.com', 587, timeout=15)
        self.assertEqual(smtp.ehlo.call_count, 2)
        context = smtp.starttls.call_args.kwargs['context']
        self.assertTrue(context.check_hostname)
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
        smtp.login.assert_called_once_with('qa.sender@gmail.com', 'abcdefghijklmnop')
        names = [call[0] for call in smtp.mock_calls]
        self.assertLess(names.index('starttls'), names.index('login'))
        smtp.sendmail.assert_not_called()
        smtp.send_message.assert_not_called()


if __name__ == '__main__':
    unittest.main()
