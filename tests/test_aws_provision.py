"""Provisioning contract checks using a fake AWS CLI; creates no AWS resources."""
from pathlib import Path
import json
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FAKE_AWS = '''#!/usr/bin/env python3
from pathlib import Path
import json, os, sys
args=sys.argv[1:]
while args and args[0].startswith('--'):
    if args[0]=='--region': args=args[2:]
    else: args=args[1:]
with open(os.environ['SGI_FAKE_LOG'],'a') as f: f.write(json.dumps(args)+'\\n')
mode=os.environ.get('SGI_FAKE_MODE','new')
state=Path(os.environ['SGI_FAKE_STATE'])
command=tuple(args[:2])
if command==('sts','get-caller-identity'): print('{"Account":"123456789012"}')
elif command==('cloudformation','describe-stacks'):
    if mode=='denied':
        print('AccessDenied: not authorized',file=sys.stderr);sys.exit(255)
    if mode!='existing' and not state.exists():
        print('ValidationError: Stack does not exist',file=sys.stderr);sys.exit(255)
    if '--query' in args:
        print('203.0.113.10' if 'PublicIp' in args[args.index('--query')+1] else 'Stack outputs')
    else: print('{"Stacks":[{"StackStatus":"CREATE_COMPLETE"}]}')
elif command==('ec2','describe-instance-types'): print('False' if mode=='ineligible' else 'True')
elif command==('ssm','get-parameter'): print('ami-0123456789abcdef0')
elif command==('ec2','describe-images'):
    print(json.dumps({'Images':[{'OwnerId':'000000000000' if mode=='wrong-owner' else '099720109477',
                               'Architecture':'x86_64','State':'available',
                               'FreeTierEligible':True,'RootDeviceName':'/dev/sda1'}]}))
elif command==('ec2','describe-instance-type-offerings'): print('us-east-1a')
elif command==('cloudformation','validate-template'): print('{}')
elif command==('cloudformation','create-stack'):
    path=args[args.index('--parameters')+1].removeprefix('file://')
    state.write_text(Path(path).read_text())
    print('{"StackId":"test-stack"}')
elif command==('cloudformation','wait'): pass
else:
    raise SystemExit('Unexpected AWS request: '+str(args))
'''


class ProvisionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.base = Path(self.directory.name)
        fake = self.base / 'aws'
        fake.write_text(FAKE_AWS)
        fake.chmod(0o700)
        self.key = self.base / 'admin-key'
        self.log = self.base / 'requests.jsonl'
        self.state = self.base / 'parameters.json'
        self.env = dict(os.environ)
        self.env.update(PATH=str(self.base) + os.pathsep + self.env['PATH'],
                        SGI_FAKE_LOG=str(self.log), SGI_FAKE_STATE=str(self.state))

    def tearDown(self):
        self.directory.cleanup()

    def run_script(self, *args, mode='new'):
        env = dict(self.env, SGI_FAKE_MODE=mode)
        return subprocess.run(['bash', str(ROOT / 'deploy/aws/provision.sh'),
                               '--ssh-cidr', '8.8.8.8/32', '--key-file', str(self.key), *args],
                              env=env, text=True, capture_output=True, timeout=20)

    def assert_no_create(self):
        records = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        self.assertFalse(any(record[:2] == ['cloudformation', 'create-stack'] for record in records))

    def test_new_stack_preserves_restore_default_and_imports_only_public_key(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        params = {p['ParameterKey']: p['ParameterValue'] for p in json.loads(self.state.read_text())}
        self.assertEqual(params['DataMode'], 'restore')
        self.assertEqual(params['SshCidr'], '8.8.8.8/32')
        self.assertTrue(params['SshPublicKey'].startswith('ssh-ed25519 '))
        self.assertNotIn('PRIVATE KEY', self.state.read_text())
        self.assertEqual(self.key.stat().st_mode & 0o777, 0o600)
        self.assertNotIn('PRIVATE KEY', result.stdout)

    def test_fresh_install_requires_explicit_mode(self):
        result = self.run_script('--mode', 'fresh')
        self.assertEqual(result.returncode, 0, result.stderr)
        params = {p['ParameterKey']: p['ParameterValue'] for p in json.loads(self.state.read_text())}
        self.assertEqual(params['DataMode'], 'fresh')

    def test_existing_stack_is_not_updated_and_key_is_not_regenerated(self):
        result = self.run_script(mode='existing')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.key.exists())
        self.assert_no_create()

    def test_access_denied_is_not_treated_as_missing_stack(self):
        result = self.run_script(mode='denied')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.key.exists())
        self.assert_no_create()

    def test_global_ssh_rule_is_rejected(self):
        result = self.run_script('--ssh-cidr', '0.0.0.0/0')
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_create()

    def test_ineligible_instance_does_not_create_resources(self):
        result = self.run_script(mode='ineligible')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.key.exists())
        self.assert_no_create()

    def test_wrong_ami_owner_does_not_create_resources(self):
        result = self.run_script(mode='wrong-owner')
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_create()

    def test_partial_key_pair_is_preserved(self):
        self.key.write_text('existing-private-material')
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.key.read_text(), 'existing-private-material')
        self.assert_no_create()


if __name__ == '__main__':
    unittest.main()
